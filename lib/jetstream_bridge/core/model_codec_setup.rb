# frozen_string_literal: true

require 'oj'

module JetstreamBridge
  module ModelCodecSetup
    module_function

    def apply!
      return unless ar_connected?

      [JetstreamBridge::OutboxEvent, JetstreamBridge::InboxEvent].each { |k| apply_to(k) }
    end

    def apply_to(klass)
      return unless table_exists_safely?(klass)

      %w[payload headers].each do |attr|
        next unless column?(klass, attr)
        next if json_column?(klass, attr) || already_serialized?(klass, attr)

        klass.serialize attr.to_sym, coder: Oj
      end
    rescue ActiveRecord::StatementInvalid, ActiveRecord::ConnectionNotEstablished, ActiveRecord::NoDatabaseError
      # ignore when schema isn’t available yet
    end

    # --- helpers ---

    def ar_connected?
      ActiveRecord::Base.connected?
    rescue StandardError
      false
    end

    def table_exists_safely?(klass)
      klass.table_exists?
    rescue StandardError
      false
    end

    def column?(klass, attr)
      klass.columns_hash.key?(attr)
    rescue StandardError
      false
    end

    def json_column?(klass, attr)
      sql = klass.columns_hash.fetch(attr).sql_type.to_s.downcase
      sql.include?('json') # covers json & jsonb
    rescue StandardError
      false
    end

    def already_serialized?(klass, attr)
      klass.attribute_types.fetch(attr, nil).is_a?(ActiveRecord::Type::Serialized)
    rescue StandardError
      false
    end
  end
end
