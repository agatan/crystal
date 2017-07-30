# Here we process the compiler's command line options and
# execute the relevant commands.
#
# Some commands are implemented in the `commands` directory,
# some in `tools`, some here, and some create a Compiler and
# manipulate it.
#
# Other commands create a `Compiler` and use it to to build
# an executable.

require "json"
require "./command/*"

class Crystal::Command
  USAGE = <<-USAGE
    Usage: crystal [command] [switches] [program file] [--] [arguments]

    Command:
        init                     generate a new project
        build                    build an executable
        deps                     install project dependencies
        docs                     generate documentation
        env                      print Crystal environment information
        eval                     eval code from args or standard input
        play                     starts crystal playground server
        run (default)            build and run program
        spec                     build and run specs (in spec directory)
        tool                     run a tool
        help, --help, -h         show this help
        version, --version, -v   show version
    USAGE

  COMMANDS_USAGE = <<-USAGE
    Usage: crystal tool [tool] [switches] [program file] [--] [arguments]

    Tool:
        context                  show context for given location
        expand                   show macro expansion for given location
        format                   format project, directories and/or files
        hierarchy                show type hierarchy
        implementations          show implementations for given call in location
        types                    show type of main variables
        --help, -h               show this help
    USAGE

  VALID_EMIT_VALUES = %w(asm llvm-bc llvm-ir obj)

  def self.run(options = ARGV)
    new(options).run
  end

  private getter options

  def initialize(@options : Array(String))
    @color = true
    @progress_tracker = ProgressTracker.new
  end

  def run
    command = options.first?

    if command
      case
      when "init".starts_with?(command)
        options.shift
        init
      when "build".starts_with?(command), "compile".starts_with?(command)
        if "compile".starts_with?(command)
          STDERR.puts "Deprecation: The compile command was renamed to build and will be removed in a future version."
        end
        options.shift
        build
      when "play".starts_with?(command)
        options.shift
        playground
      when "deps".starts_with?(command)
        options.shift
        deps
      when "docs".starts_with?(command)
        options.shift
        docs
      when command == "env"
        options.shift
        env
      when command == "eval"
        options.shift
        eval
      when "run".starts_with?(command)
        options.shift
        run_command(single_file: false)
      when "spec/".starts_with?(command)
        options.shift
        spec
      when "tool".starts_with?(command)
        options.shift
        tool
      when "help".starts_with?(command), "--help" == command, "-h" == command
        puts USAGE
        exit
      when "version".starts_with?(command), "--version" == command, "-v" == command
        puts Crystal::Config.description
        exit
      else
        if File.file?(command)
          run_command(single_file: true)
        else
          error "unknown command: #{command}"
        end
      end
    else
      puts USAGE
      exit
    end
  rescue ex : Crystal::ToolException
    error ex.message
  rescue ex : Crystal::Exception
    ex.color = @color
    if @config.try(&.output_format) == "json"
      STDERR.puts ex.to_json
    else
      STDERR.puts ex
    end
    exit 1
  rescue ex : OptionParser::Exception
    error ex.message
  rescue ex
    STDERR.puts ex
    ex.backtrace.each do |frame|
      STDERR.puts frame
    end
    STDERR.puts
    error "you've found a bug in the Crystal compiler. Please open an issue, including source code that will allow us to reproduce the bug: https://github.com/crystal-lang/crystal/issues"
  end

  private def tool
    tool = options.first?
    if tool
      case
      when "context".starts_with?(tool)
        options.shift
        context
      when "format".starts_with?(tool)
        options.shift
        format
      when "expand".starts_with?(tool)
        options.shift
        expand
      when "hierarchy".starts_with?(tool)
        options.shift
        hierarchy
      when "implementations".starts_with?(tool)
        options.shift
        implementations
      when "types".starts_with?(tool)
        options.shift
        types
      when "--help" == tool, "-h" == tool
        puts COMMANDS_USAGE
        exit
      else
        error "unknown tool: #{tool}"
      end
    else
      puts COMMANDS_USAGE
      exit
    end
  end

  private def init
    Init.run(options)
  end

  private def build
    config = create_compiler "build"
    config.compile
  end

  private def hierarchy
    config, result = compile_no_codegen "tool hierarchy", hierarchy: true, top_level: true
    @progress_tracker.stage("Tool (hierarchy)") do
      Crystal.print_hierarchy result.program, config.hierarchy_exp, config.output_format
    end
  end

  private def run_command(single_file = false)
    config = create_compiler "run", run: true, single_file: single_file
    if config.specified_output
      config.compile
      return
    end

    output_filename = Crystal.tempfile(config.output_filename)

    result = config.compile output_filename
    execute output_filename, config.arguments unless config.compiler.no_codegen?
  end

  private def types
    config, result = compile_no_codegen "tool types"
    @progress_tracker.stage("Tool (types)") do
      Crystal.print_types result.node
    end
  end

  private def compile_no_codegen(command, wants_doc = false, hierarchy = false, no_cleanup = false, cursor_command = false, top_level = false)
    config = create_compiler command, no_codegen: true, hierarchy: hierarchy, cursor_command: cursor_command
    config.compiler.no_codegen = true
    config.compiler.no_cleanup = no_cleanup
    config.compiler.wants_doc = wants_doc
    result = top_level ? config.top_level_semantic : config.compile
    {config, result}
  end

  private def execute(output_filename, run_args)
    time? = @time && !@progress_tracker.stats?
    status, elapsed_time = @progress_tracker.stage("Execute") do
      begin
        start_time = Time.now
        Process.run(output_filename, args: run_args, input: true, output: true, error: true) do |process|
          # Ignore the signal so we don't exit the running process
          # (the running process can still handle this signal)
          Signal::INT.ignore # do
        end
        {$?, Time.now - start_time}
      ensure
        File.delete(output_filename) rescue nil
      end
    end

    if time?
      puts "Execute: #{elapsed_time}"
    end

    if status.normal_exit?
      exit status.exit_code
    else
      case status.exit_signal
      when Signal::KILL
        STDERR.puts "Program was killed"
      when Signal::SEGV
        STDERR.puts "Program exited because of a segmentation fault (11)"
      when Signal::INT
        # OK, bubbled from the sub-program
      else
        STDERR.puts "Program received and didn't handle signal #{status.exit_signal} (#{status.exit_signal.value})"
      end

      exit 1
    end
  end

  record CompilerConfig,
    compiler : Compiler,
    sources : Array(Compiler::Source),
    output_filename : String,
    original_output_filename : String,
    arguments : Array(String),
    specified_output : Bool,
    hierarchy_exp : String?,
    cursor_location : String?,
    output_format : String? do
    def compile(output_filename = self.output_filename)
      compiler.emit_base_filename = original_output_filename
      compiler.compile sources, output_filename
    end

    def top_level_semantic
      compiler.top_level_semantic sources
    end
  end

  private def create_compiler(command, no_codegen = false, run = false,
                              hierarchy = false, cursor_command = false,
                              single_file = false)
    compiler = Compiler.new
    compiler.progress_tracker = @progress_tracker
    link_flags = [] of String
    opt_filenames = nil
    opt_arguments = nil
    opt_output_filename = nil
    specified_output = false
    hierarchy_exp = nil
    cursor_location = nil
    output_format = nil

    option_parser = OptionParser.parse(options) do |opts|
      opts.banner = "Usage: crystal #{command} [options] [programfile] [--] [arguments]\n\nOptions:"

      unless no_codegen
        unless run
          opts.on("--cross-compile", "cross-compile") do |cross_compile|
            compiler.cross_compile = true
          end
        end
        opts.on("-d", "--debug", "Add full symbolic debug info") do
          compiler.debug = Crystal::Debug::All
        end
        opts.on("--no-debug", "Skip any symbolic debug info") do
          compiler.debug = Crystal::Debug::None
        end
      end

      opts.on("-D FLAG", "--define FLAG", "Define a compile-time flag") do |flag|
        compiler.flags << flag
      end

      unless no_codegen
        opts.on("--emit [#{VALID_EMIT_VALUES.join("|")}]", "Comma separated list of types of output for the compiler to emit") do |emit_values|
          compiler.emit = validate_emit_values(emit_values.split(',').map(&.strip))
        end
      end

      if hierarchy
        opts.on("-e NAME", "Filter types by NAME regex") do |exp|
          hierarchy_exp = exp
        end
      end

      if cursor_command
        opts.on("-c LOC", "--cursor LOC", "Cursor location with LOC as path/to/file.cr:line:column") do |cursor|
          cursor_location = cursor
        end
      end

      opts.on("-f text|json", "--format text|json", "Output format text (default) or json") do |f|
        output_format = f
      end

      opts.on("--error-trace", "Show full error trace") do
        compiler.show_error_trace = true
      end

      opts.on("-h", "--help", "Show this message") do
        puts opts
        exit
      end

      unless no_codegen
        opts.on("--ll", "Dump ll to Crystal's cache directory") do
          compiler.dump_ll = true
        end
        opts.on("--link-flags FLAGS", "Additional flags to pass to the linker") do |some_link_flags|
          link_flags << some_link_flags
        end
        opts.on("--mcpu CPU", "Target specific cpu type") do |cpu|
          compiler.mcpu = cpu
        end
        opts.on("--mattr CPU", "Target specific features") do |features|
          compiler.mattr = features
        end
      end

      opts.on("--no-color", "Disable colored output") do
        @color = false
        compiler.color = false
      end

      unless no_codegen
        opts.on("--no-codegen", "Don't do code generation") do
          compiler.no_codegen = true
        end
        opts.on("-o ", "Output filename") do |an_output_filename|
          opt_output_filename = an_output_filename
          specified_output = true
        end
      end

      opts.on("--prelude ", "Use given file as prelude") do |prelude|
        compiler.prelude = prelude
      end

      unless no_codegen
        opts.on("--release", "Compile in release mode") do
          compiler.release = true
        end
      end

      opts.on("-s", "--stats", "Enable statistics output") do
        @progress_tracker.stats = true
      end

      opts.on("-p", "--progress", "Enable progress output") do
        @progress_tracker.progress = true
      end

      opts.on("-t", "--time", "Enable execution time output") do
        @time = true
      end

      unless no_codegen
        opts.on("--single-module", "Generate a single LLVM module") do
          compiler.single_module = true
        end
        opts.on("--threads ", "Maximum number of threads to use") do |n_threads|
          compiler.n_threads = n_threads.to_i
        end
        unless run
          opts.on("--target TRIPLE", "Target triple") do |triple|
            compiler.target_triple = triple
          end
        end
        opts.on("--verbose", "Display executed commands") do
          compiler.verbose = true
        end
      end

      opts.unknown_args do |before, after|
        opt_filenames = before
        opt_arguments = after
      end
    end

    compiler.link_flags = link_flags.join(" ") unless link_flags.empty?

    output_filename = opt_output_filename
    filenames = opt_filenames.not_nil!
    arguments = opt_arguments.not_nil!

    if single_file && filenames.size > 1
      arguments = filenames[1..-1] + arguments
      filenames = [filenames[0]]
    end

    if filenames.size == 0 || (cursor_command && cursor_location.nil?)
      STDERR.puts option_parser
      exit 1
    end

    sources = gather_sources(filenames)
    first_filename = sources.first.filename
    first_file_ext = File.extname(first_filename)
    original_output_filename = File.basename(first_filename, first_file_ext)

    # Check if we'll overwrite the main source file
    if first_file_ext.empty? && !output_filename && !no_codegen && !run && first_filename == File.expand_path(original_output_filename)
      error "compilation will overwrite source file '#{Crystal.relative_filename(first_filename)}', either change its extension to '.cr' or specify an output file with '-o'"
    end

    output_filename ||= original_output_filename
    output_format ||= "text"
    if !["text", "json"].includes?(output_format)
      error "You have input an invalid format, only text and JSON are supported"
    end

    if !no_codegen && !run && Dir.exists?(output_filename)
      error "can't use `#{output_filename}` as output filename because it's a directory"
    end

    @config = CompilerConfig.new compiler, sources, output_filename, original_output_filename, arguments, specified_output, hierarchy_exp, cursor_location, output_format
  end

  private def gather_sources(filenames)
    filenames.map do |filename|
      unless File.file?(filename)
        error "File #{filename} does not exist"
      end
      filename = File.expand_path(filename)
      Compiler::Source.new(filename, File.read(filename))
    end
  end

  private def setup_simple_compiler_options(compiler, opts)
    opts.on("-d", "--debug", "Add full symbolic debug info") do
      compiler.debug = Crystal::Debug::All
    end
    opts.on("--no-debug", "Skip any symbolic debug info") do
      compiler.debug = Crystal::Debug::None
    end
    opts.on("-D FLAG", "--define FLAG", "Define a compile-time flag") do |flag|
      compiler.flags << flag
    end
    opts.on("--error-trace", "Show full error trace") do
      compiler.show_error_trace = true
    end
    opts.on("--release", "Compile in release mode") do
      compiler.release = true
    end
    opts.on("-s", "--stats", "Enable statistics output") do
      compiler.progress_tracker.stats = true
    end
    opts.on("-p", "--progress", "Enable progress output") do
      compiler.progress_tracker.progress = true
    end
    opts.on("-t", "--time", "Enable execution time output") do
      @time = true
    end
    opts.on("-h", "--help", "Show this message") do
      puts opts
      exit
    end
    opts.on("--no-color", "Disable colored output") do
      @color = false
      compiler.color = false
    end
    opts.invalid_option { }
  end

  private def validate_emit_values(values)
    values.each do |value|
      unless VALID_EMIT_VALUES.includes?(value)
        error "invalid emit value '#{value}'"
      end
    end
    values
  end

  private def error(msg, exit_code = 1)
    # This is for the case where the main command is wrong
    @color = false if ARGV.includes?("--no-color")
    Crystal.error msg, @color, exit_code: exit_code
  end
end
