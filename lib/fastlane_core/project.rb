module FastlaneCore
  # Represents an Xcode project
  class Project
    class << self
      # Project discovery
      def detect_projects(config)
        if config[:workspace].to_s.length > 0 and config[:project].to_s.length > 0
          raise "You can only pass either a workspace or a project path, not both".red
        end

        return if config[:project].to_s.length > 0

        if config[:workspace].to_s.length == 0
          workspace = Dir["./*.xcworkspace"]
          if workspace.count > 1
            puts "Select Workspace: "
            config[:workspace] = choose(*(workspace))
          else
            config[:workspace] = workspace.first # this will result in nil if no files were found
          end
        end

        return if config[:workspace].to_s.length > 0

        if config[:workspace].to_s.length == 0 and config[:project].to_s.length == 0
          project = Dir["./*.xcodeproj"]
          if project.count > 1
            puts "Select Project: "
            config[:project] = choose(*(project))
          else
            config[:project] = project.first # this will result in nil if no files were found
          end
        end

        if config[:workspace].nil? and config[:project].nil?
          select_project(config)
        end
      end

      def select_project(config)
        loop do
          path = ask("Couldn't automatically detect the project file, please provide a path: ".yellow).strip
          if File.directory? path
            if path.end_with? ".xcworkspace"
              config[:workspace] = path
              break
            elsif path.end_with? ".xcodeproj"
              config[:project] = path
              break
            else
              Helper.log.error "Path must end with either .xcworkspace or .xcodeproj"
            end
          else
            Helper.log.error "Couldn't find project at path '#{File.expand_path(path)}'".red
          end
        end
      end
    end

    # Path to the project/workspace
    attr_accessor :path

    # Is this project a workspace?
    attr_accessor :is_workspace

    # The config object containing the scheme, configuration, etc.
    attr_accessor :options

    def initialize(options)
      self.options = options
      self.path = File.expand_path(options[:workspace] || options[:project])
      self.is_workspace = (options[:workspace].to_s.length > 0)

      if !path or !File.directory?(path)
        raise "Could not find project at path '#{path}'".red
      end
    end

    def workspace?
      self.is_workspace
    end

    # Get all available schemes in an array
    def schemes
      results = []
      output = raw_info.split("Schemes:").last.split(":").first

      if raw_info.include?("There are no schemes in workspace") or raw_info.include?("This project contains no schemes")
        return results
      end

      output.split("\n").each do |current|
        current = current.strip

        next if current.length == 0
        results << current
      end

      results
    end

    # Let the user select a scheme
    def select_scheme
      if options[:scheme].to_s.length > 0
        # Verify the scheme is available
        unless schemes.include?(options[:scheme].to_s)
          Helper.log.error "Couldn't find specified scheme '#{options[:scheme]}'.".red
          options[:scheme] = nil
        end
      end

      return if options[:scheme].to_s.length > 0

      if schemes.count == 1
        options[:scheme] = schemes.last
      elsif schemes.count > 1
        if Helper.is_ci?
          Helper.log.error "Multiple schemes found but you haven't specified one.".red
          Helper.log.error "Since this is a CI, please pass one using the `scheme` option".red
          raise "Multiple schemes found".red
        else
          puts "Select Scheme: "
          options[:scheme] = choose(*(schemes))
        end
      else
        Helper.log.error "Couldn't find any schemes in this project, make sure that the scheme is shared if you are using a workspace".red
        Helper.log.error "Open Xcode, click on `Manage Schemes` and check the `Shared` box for the schemes you want to use".red

        raise "No Schemes found".red
      end
    end

    # Get all available configurations in an array
    def configurations
      results = []
      splitted = raw_info.split("Configurations:")
      return [] if splitted.count != 2 # probably a CocoaPods project

      output = splitted.last.split(":").first
      output.split("\n").each_with_index do |current, index|
        current = current.strip

        if current.length == 0
          next if index == 0
          break # as we want to break on the empty line
        end

        results << current
      end

      results
    end

    def default_app_identifier
      scheme = schemes.first if is_workspace
      default_build_settings(key: "PRODUCT_BUNDLE_IDENTIFIER", scheme: scheme)
    end

    def default_app_name
      if is_workspace
        scheme = schemes.first
        return default_build_settings(key: "PRODUCT_NAME", scheme: scheme)
      else
        return app_name
      end
    end

    def app_name
      # WRAPPER_NAME: Example.app
      # WRAPPER_SUFFIX: .app
      name = build_settings(key: "WRAPPER_NAME")

      return name.gsub(build_settings(key: "WRAPPER_SUFFIX"), "") if name
      return "App" # default value
    end

    def mac?
      # Some projects have different values... we have to look for all of them
      return true if build_settings(key: "PLATFORM_NAME") == "macosx"
      return true if build_settings(key: "PLATFORM_DISPLAY_NAME") == "OS X"
      false
    end

    def tvos?
      return true if build_settings(key: "PLATFORM_NAME").to_s.include? "appletv"
      return true if build_settings(key: "PLATFORM_DISPLAY_NAME").to_s.include? "tvOS"
      false
    end

    def ios?
      !mac? && !tvos?
    end

    def xcodebuild_parameters
      proj = []
      proj << "-workspace '#{options[:workspace]}'" if options[:workspace]
      proj << "-scheme '#{options[:scheme]}'" if options[:scheme]
      proj << "-project '#{options[:project]}'" if options[:project]

      return proj
    end

    #####################################################
    # @!group Raw Access
    #####################################################

    # Get the build settings for our project
    # this is used to properly get the DerivedData folder
    # @param [String] The key of which we want the value for (e.g. "PRODUCT_NAME")
    def build_settings(key: nil, optional: true, silent: false)
      unless @build_settings
        # We also need to pass the workspace and scheme to this command
        command = "xcrun xcodebuild -showBuildSettings #{xcodebuild_parameters.join(' ')}"
        Helper.log.info command.yellow unless silent
        @build_settings = `#{command}`
      end

      begin
        result = @build_settings.split("\n").find { |c| c.split(" = ").first.strip == key }
        return result.split(" = ").last
      rescue => ex
        return nil if optional # an optional value, we really don't care if something goes wrong

        Helper.log.error caller.join("\n\t")
        Helper.log.error "Could not fetch #{key} from project file: #{ex}"
      end

      nil
    end

    def default_build_settings(key: nil, optional: true, silent: false, scheme: nil)
      options[:scheme] = scheme if scheme
      build_settings(key: key, optional: optional, silent: silent)
    end

    def raw_info(silent: false)
      # Examples:

      # Standard:
      #
      # Information about project "Example":
      #     Targets:
      #         Example
      #         ExampleUITests
      #
      #     Build Configurations:
      #         Debug
      #         Release
      #
      #     If no build configuration is specified and -scheme is not passed then "Release" is used.
      #
      #     Schemes:
      #         Example
      #         ExampleUITests

      # CococaPods
      #
      # Example.xcworkspace
      # Information about workspace "Example":
      #     Schemes:
      #         Example
      #         HexColors
      #         Pods-Example

      return @raw if @raw

      # Unfortunately since we pass the workspace we also get all the
      # schemes generated by CocoaPods

      options = xcodebuild_parameters.delete_if { |a| a.to_s.include? "scheme" }
      command = "xcrun xcodebuild -list #{options.join(' ')}"
      Helper.log.info command.yellow unless silent

      @raw = `#{command}`.to_s

      raise "Error parsing xcode file using `#{command}`".red if @raw.length == 0

      return @raw
    end
  end
end
