# frozen_string_literal: true

require "yaml"

module Net
  module Connector
    # Host-side configuration discovery. Requiring this file never loads device I/O.
    class Config
      NAMES = %w[vxlan wireless backup topology].freeze
      COMMON_KEYS = %w[netdisco inventory ssh].freeze
      CONFIG_ENV = { "vxlan" => "VXLAN_CONFIG", "wireless" => "WIRELESS_CONFIG",
                     "backup" => "NC_CONFIG", "topology" => "NC_CONFIG" }.freeze

      attr_reader :data, :specific, :process_environment, :file_environment, :environment,
                  :config_files, :environment_files, :sources

      def initialize(name:, env: ENV, script: $PROGRAM_NAME, cwd: Dir.pwd, home: Dir.home,
                     directories: nil, config: nil, env_file: nil, config_env: nil,
                     path_fields: [], env_path_keys: [], path_literals: {})
        @name = name.to_s
        raise ArgumentError, "unsupported configuration name: #{@name}" unless NAMES.include?(@name)

        @cwd = File.expand_path(cwd)
        @home = File.expand_path(home)
        @config_env = config_env || CONFIG_ENV.fetch(@name)
        @env_path_keys = (env_path_keys.map(&:to_s) + [@config_env]).uniq
        @path_literals = self.class.freeze_tree(self.class.copy(path_literals.transform_keys(&:to_s)))
        @process_environment = self.class.copy(env.to_h)
        resolve_environment_paths!(@process_environment, @cwd)
        self.class.freeze_tree(@process_environment)
        @user_directory = File.join(user_config_home, "net-connector")
        @directories = (directories || ["/etc/net-connector", "/usr/local/etc/net-connector", @user_directory,
                                        File.dirname(File.expand_path(script, @cwd)), @cwd]).map do |path|
          File.expand_path(path, @cwd)
        end.uniq
        @explicit_config = absolute(config, @cwd)
        @explicit_env_file = absolute(env_file, @cwd)
        @path_fields = path_fields.map { |path| path.to_s.split(".") }
        @data = @specific = @file_environment = @environment = {}.freeze
        @config_files = @environment_files = [].freeze
        @sources = { "configuration_files" => @config_files, "environment_files" => @environment_files, "fields" => {}.freeze }.freeze
      end

      # Read environment files without mutating ENV or evaluating any YAML.
      def load_environment(allow_missing: false)
        return self if @environment_loaded

        files = candidates(".env", @explicit_env_file)
        values = {}
        loaded = []
        files.each do |path|
          next unless readable_file?(path, explicit: path == @explicit_env_file, allow_missing: allow_missing)

          parsed = parse_environment(path, values.merge(@process_environment))
          resolve_environment_paths!(parsed, File.dirname(path))
          values.merge!(parsed)
          loaded << path
        end
        @file_environment = self.class.freeze_tree(values)
        @environment = self.class.freeze_tree(values.merge(self.class.copy(@process_environment)))
        @environment_files = self.class.freeze_tree(loaded)
        # Empty selectors are absent, including an empty original process variable.
        selector = present(@process_environment[@config_env]) || present(values[@config_env])
        @selected_config = @explicit_config || absolute(selector, @cwd)
        @environment_loaded = true
        update_sources({})
        self
      end

      # Freeze one batch snapshot; repeated calls do not re-read files.
      def load(allow_missing: false)
        return self if @loaded

        load_environment(allow_missing: allow_missing)
        merged = {}
        specific = {}
        fields = {}
        loaded = []
        @applicable = false
        paths = @directories.flat_map { |directory| [File.join(directory, "net-connector.yml"), File.join(directory, "#{@name}.yml")] }
        paths = final_candidates(paths, @selected_config)
        paths.each do |path|
          next unless readable_file?(path, explicit: path == @selected_config, allow_missing: allow_missing)

          document = read_yaml(path)
          if File.basename(path) == "net-connector.yml"
            common, native, applicable = shared_sections(document, path)
            merged = merge_layer(merged, common, path, fields)
            @applicable ||= applicable
          else
            native = document
            validate_string_keys!(native, path)
            @applicable = true
          end
          merged = merge_layer(merged, native, path, fields)
          specific = self.class.merge(specific, resolve_paths(native, path))
          loaded << path
        end
        @data = self.class.freeze_tree(merged)
        @specific = self.class.freeze_tree(specific)
        @config_files = self.class.freeze_tree(loaded)
        update_sources(fields)
        @loaded = true
        self
      end

      def config
        @selected_config || @explicit_config || @config_files.last || init_config
      end

      def env_file
        @explicit_env_file || @environment_files.last || init_env_file
      end

      def init_config
        @selected_config || @explicit_config || File.join(@user_directory, "#{@name}.yml")
      end

      def init_env_file
        @explicit_env_file || File.join(@user_directory, ".env")
      end

      def missing?
        !@applicable
      end

      # Serialize native values using the same target-file schema as discovery.
      def self.dump(document, name:, path:)
        name = name.to_s
        raise ArgumentError, "unsupported configuration name: #{name}" unless NAMES.include?(name)

        YAML.dump(File.basename(path) == "net-connector.yml" ? { name => document } : document)
      end

      # Recursive, non-destructive replacement: arrays, false and nil are values.
      def self.merge(*hashes)
        hashes.reduce({}) do |result, hash|
          hash.each do |key, value|
            result[copy(key)] = result[key].is_a?(Hash) && value.is_a?(Hash) ? merge(result[key], value) : copy(value)
          end
          result
        end
      end

      def self.copy(value)
        case value
        when Hash then value.to_h { |key, entry| [copy(key), copy(entry)] }
        when Array then value.map { |entry| copy(entry) }
        when String then value.dup
        else value
        end
      end

      def self.freeze_tree(value)
        case value
        when Hash then value.each { |key, entry| freeze_tree(key); freeze_tree(entry) }
        when Array then value.each { |entry| freeze_tree(entry) }
        end
        value.freeze
      end

      private

      def present(value)
        value unless value.nil? || value.to_s.strip.empty?
      end

      def absolute(path, directory)
        File.expand_path(path.to_s, directory) if present(path)
      end

      def user_config_home
        absolute(present(@process_environment["XDG_CONFIG_HOME"]), @cwd) || File.join(@home, ".config")
      end

      def candidates(filename, explicit)
        final_candidates(@directories.map { |directory| File.join(directory, filename) }, explicit)
      end

      def final_candidates(paths, explicit)
        paths = paths.reject { |path| path == explicit } + [explicit] if explicit
        paths.uniq
      end

      def readable_file?(path, explicit:, allow_missing:)
        unless File.exist?(path)
          raise ArgumentError, "configuration file does not exist: #{path}" if explicit && !allow_missing

          return false
        end
        return true if File.file?(path) && File.readable?(path)

        raise ArgumentError, "configuration path is not a readable regular file: #{path}"
      end

      def read_yaml(path)
        contents = File.read(path)
        validate_yaml_structure!(contents, path)
        document = YAML.safe_load(contents, permitted_classes: [], permitted_symbols: [], aliases: false)
        document = {} if document.nil?
        raise ArgumentError, "configuration must contain a mapping: #{path}" unless document.is_a?(Hash)

        document
      rescue Psych::Exception, SystemCallError, IOError => error
        raise ArgumentError, "cannot read configuration file: #{path} (#{error.class})", cause: nil
      end

      # Overrides are explicit file layers; one file cannot hide duplicate keys
      # or silently discard later documents before the tool validates its scope.
      def validate_yaml_structure!(contents, path)
        stream = YAML.parse_stream(contents)
        raise ArgumentError, "configuration must contain a single YAML document: #{path}" if stream.children.size > 1

        stream.each do |node|
          next unless node.is_a?(Psych::Nodes::Mapping)

          keys = {}
          node.children.each_slice(2) do |key, _|
            next unless key.is_a?(Psych::Nodes::Scalar)
            if keys.key?(key.value)
              raise ArgumentError, "duplicate configuration key at line #{key.start_line + 1}: #{path}"
            end

            keys[key.value] = true
          end
        end
      end

      def validate_string_keys!(value, path)
        case value
        when Hash
          raise ArgumentError, "configuration keys must be strings: #{path}" unless value.keys.all?(String)

          value.each_value { |entry| validate_string_keys!(entry, path) }
        when Array
          value.each { |entry| validate_string_keys!(entry, path) }
        end
      end

      def shared_sections(document, path)
        unknown = document.keys - ["common", *NAMES]
        raise ArgumentError, "unknown shared configuration namespaces in #{path}: #{unknown.join(", ")}" unless unknown.empty?

        common = document.fetch("common", {})
        native = document.fetch(@name, {})
        unless common.is_a?(Hash) && native.is_a?(Hash)
          raise ArgumentError, "common and #{@name} configuration must contain mappings: #{path}"
        end
        unknown_common = common.keys - COMMON_KEYS
        unless unknown_common.empty?
          raise ArgumentError, "unsupported common configuration fields in #{path}: #{unknown_common.join(", ")}"
        end
        validate_string_keys!(common, path)
        validate_string_keys!(native, path)
        [common, native, document.key?(@name)]
      end

      def resolve_paths(document, path)
        result = self.class.copy(document)
        @path_fields.each { |segments| resolve_path!(result, segments, File.dirname(path), segments.join(".")) }
        result
      end

      def resolve_path!(value, segments, directory, field)
        return unless value.is_a?(Hash) && !segments.empty?

        key, *rest = segments
        keys = key == "*" ? value.keys : [key]
        keys.each do |entry|
          next unless value.key?(entry)

          if rest.empty?
            value[entry] = declared_path(value[entry], directory, field) if value[entry].is_a?(String) && !value[entry].empty?
          else
            resolve_path!(value[entry], rest, directory, field)
          end
        end
      end

      # Declared paths may identify remote archive roots as well as local files.
      def declared_path(value, directory, field)
        raise ArgumentError if value.to_s.include?("\0")

        return value if @path_literals.fetch(field, []).include?(value)

        value.to_s.match?(%r{\A[A-Za-z][A-Za-z0-9+.-]*://}) ? value : absolute(value, directory)
      rescue ArgumentError
        raise ArgumentError, "invalid path #{field}", cause: nil
      end

      def resolve_environment_paths!(values, directory)
        @env_path_keys.each do |key|
          values[key] = declared_path(values[key], directory, key) if present(values[key])
        end
      end

      def merge_layer(previous, document, path, fields)
        resolved = resolve_paths(document, path)
        record_fields(resolved, path, fields, previous: previous)
        self.class.merge(previous, resolved)
      end

      def record_fields(document, source, fields, prefix = nil, previous: {})
        document.each do |key, value|
          name = [prefix, key].compact.join(".")
          before = previous.is_a?(Hash) ? previous[key] : nil
          next if value.is_a?(Hash) && value.empty? && before.is_a?(Hash) && !before.empty?

          if value.is_a?(Hash) && !value.empty?
            fields.delete(name)
            record_fields(value, source, fields, name, previous: before)
          else
            fields.delete_if { |field, _| field == name || field.start_with?("#{name}.") }
            fields[name] = source
          end
        end
      end

      def update_sources(fields)
        @sources = self.class.freeze_tree({ "configuration_files" => @config_files,
                                            "environment_files" => @environment_files, "fields" => fields })
      end

      # Dotenv's grammar is reused, but substitutions are deliberately isolated:
      # its default implementation reads real ENV and executes shell commands.
      def parse_environment(path, inherited)
        require "dotenv"
        process = @process_environment
        variable_pattern = Dotenv::Substitutions::Variable.singleton_class.const_get(:VARIABLE)
        parser_class = Class.new(Dotenv::Parser) do
          define_singleton_method(:substitutions) do
            [lambda do |value, local|
              raise ArgumentError, "command substitution is unsupported" if value.include?("$(")

              value.gsub(variable_pattern) do |variable|
                match = Regexp.last_match
                if match[1] == "\\"
                  variable[1..]
                elsif match[3]
                  process.fetch(match[3]) { local.fetch(match[3]) { inherited.fetch(match[3], "") } }
                else
                  variable
                end
              end
            end]
          end
          define_method(:expand_newlines) do |value|
            if (@hash["DOTENV_LINEBREAK_MODE"] || inherited["DOTENV_LINEBREAK_MODE"]) == "legacy"
              value.gsub('\\n', "\n").gsub('\\r', "\r")
            else
              value.gsub('\\n', "\\\\\\n").gsub('\\r', "\\\\\\r")
            end
          end
          private :expand_newlines
        end
        contents = File.read(path)
        remainder = contents.gsub(Dotenv::Parser::LINE, "")
        unless remainder.lines.all? { |line| line.strip.empty? || line.lstrip.start_with?("#") }
          raise ArgumentError, "invalid environment syntax"
        end
        parser_class.call(contents, overwrite: true)
      rescue Dotenv::FormatError, ArgumentError, SystemCallError, IOError => error
        raise ArgumentError, "cannot read environment file: #{path} (#{error.class})"
      end
    end
  end
end
