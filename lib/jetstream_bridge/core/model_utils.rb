# frozen_string_literal: true

module JetstreamBridge
  module ModelUtils
    module_function

    def constantize(name)
      name.to_s.split('::').reduce(Object) { |m, c| m.const_get(c) }
    end

    def ar_class?(klass)
      defined?(ActiveRecord::Base) && klass <= ActiveRecord::Base
    end

    def has_columns?(klass, *cols)
      return false unless ar_class?(klass)
      cols.flatten.all? { |c| klass.column_names.include?(c.to_s) }
    end

    def assign_known_attrs(record, attrs)
      attrs.each do |k, v|
        setter = :"#{k}="
        record.public_send(setter, v) if record.respond_to?(setter)
      end
    end

    # find_or_initialize_by on the first keyset whose columns exist; else new
    def find_or_init_by_best(klass, *keysets)
      keysets.each do |keys|
        next if keys.nil? || keys.empty?
        if has_columns?(klass, keys.keys)
          return klass.find_or_initialize_by(keys)
        end
      end
      klass.new
    end

    def json_dump(obj)
      obj.is_a?(String) ? obj : JSON.generate(obj)
    rescue
      obj.to_s
    end

    def json_load(str)
      return str if str.is_a?(Hash)
      JSON.parse(str.to_s)
    rescue
      {}
    end
  end
end
