# frozen_string_literal: true

module JetstreamBridge
  module ConsumerModeResolver
    VALID_MODES = [:pull, :push].freeze

    module_function

    # Resolve consumer mode for a given app.
    #
    # Priority:
    # 1) explicit override (symbol/string)
    # 2) env map CONSUMER_MODES="app:mode,..."
    # 3) per-app env CONSUMER_MODE_<APP_NAME>
    # 4) shared env CONSUMER_MODE
    # 5) fallback (default :pull)
    def resolve(app_name:, override: nil, fallback: :pull)
      return normalize(override) if override

      from_env = env_for(app_name)
      return from_env if from_env

      normalize(fallback)
    end

    def env_for(app_name)
      from_map(app_name) || app_specific(app_name) || shared
    end

    def from_map(app_name)
      env_map = ENV.fetch('CONSUMER_MODES', nil)
      return nil if env_map.to_s.strip.empty?

      pairs = env_map.split(',').each_with_object({}) do |pair, memo|
        key, mode = pair.split(':', 2).map { |p| p&.strip }
        memo[key] = mode if key && mode
      end

      normalize(pairs[app_name.to_s]) if pairs.key?(app_name.to_s)
    end

    def app_specific(app_name)
      key = "CONSUMER_MODE_#{app_name.to_s.upcase}"
      return nil unless ENV.key?(key)

      normalize(ENV.fetch(key, nil))
    end

    def shared
      return nil unless ENV['CONSUMER_MODE']

      normalize(ENV.fetch('CONSUMER_MODE', nil))
    end

    def normalize(mode)
      return nil if mode.nil? || mode.to_s.strip.empty?

      m = mode.to_s.downcase.to_sym
      return m if VALID_MODES.include?(m)

      raise ArgumentError, "Invalid consumer mode #{mode.inspect}. Use :pull or :push."
    end
  end
end
