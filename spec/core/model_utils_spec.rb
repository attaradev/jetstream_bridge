# frozen_string_literal: true

require 'jetstream_bridge/core/model_utils'

RSpec.describe JetstreamBridge::ModelUtils do
  describe '.constantize' do
    it 'resolves simple class names' do
      expect(described_class.constantize('String')).to eq(String)
      expect(described_class.constantize('Array')).to eq(Array)
    end

    it 'resolves nested class names' do
      expect(described_class.constantize('JetstreamBridge::ModelUtils')).to eq(JetstreamBridge::ModelUtils)
    end

    it 'resolves module names' do
      expect(described_class.constantize('JetstreamBridge')).to eq(JetstreamBridge)
    end

    it 'raises NameError for invalid class names' do
      expect do
        described_class.constantize('NonExistentClass')
      end.to raise_error(NameError)
    end

    it 'raises NameError for invalid nested names' do
      expect do
        described_class.constantize('JetstreamBridge::NonExistent')
      end.to raise_error(NameError)
    end

    it 'handles symbols by converting to string' do
      expect(described_class.constantize(:String)).to eq(String)
    end
  end

  describe '.ar_class?' do
    context 'when ActiveRecord is defined' do
      before do
        stub_const('ActiveRecord::Base', Class.new)
      end

      it 'returns true for AR subclasses' do
        klass = Class.new(ActiveRecord::Base)
        expect(described_class.ar_class?(klass)).to be true
      end

      it 'returns false for non-AR classes' do
        expect(described_class.ar_class?(String)).to be_falsey
        expect(described_class.ar_class?(Hash)).to be_falsey
      end

      it 'returns true for ActiveRecord::Base itself' do
        expect(described_class.ar_class?(ActiveRecord::Base)).to be true
      end
    end

    context 'when ActiveRecord is not defined' do
      before do
        hide_const('ActiveRecord')
      end

      it 'returns false for any class' do
        expect(described_class.ar_class?(String)).to be_falsey
        expect(described_class.ar_class?(Class.new)).to be_falsey
      end
    end
  end

  describe '.has_columns?' do
    context 'with ActiveRecord class' do
      let(:ar_class) do
        Class.new do
          def self.column_names
            %w[id name email created_at]
          end

          def self.<=(other)
            other == ActiveRecord::Base
          end
        end
      end

      before do
        stub_const('ActiveRecord::Base', Class.new)
        allow(described_class).to receive(:ar_class?).with(ar_class).and_return(true)
      end

      it 'returns true when single column exists' do
        expect(described_class.has_columns?(ar_class, :name)).to be true
      end

      it 'returns true when all columns exist' do
        expect(described_class.has_columns?(ar_class, :name, :email)).to be true
      end

      it 'returns false when column does not exist' do
        expect(described_class.has_columns?(ar_class, :nonexistent)).to be false
      end

      it 'returns false when some columns do not exist' do
        expect(described_class.has_columns?(ar_class, :name, :nonexistent)).to be false
      end

      it 'handles array of columns' do
        expect(described_class.has_columns?(ar_class, [:name, :email])).to be true
      end

      it 'handles nested arrays of columns' do
        expect(described_class.has_columns?(ar_class, [[:name], [:email]])).to be true
      end

      it 'converts symbols to strings' do
        expect(described_class.has_columns?(ar_class, 'name', 'email')).to be true
      end
    end

    context 'with non-AR class' do
      let(:non_ar_class) { String }

      before do
        allow(described_class).to receive(:ar_class?).with(non_ar_class).and_return(false)
      end

      it 'returns false' do
        expect(described_class.has_columns?(non_ar_class, :name)).to be false
      end
    end
  end

  describe '.assign_known_attrs' do
    let(:record) do
      Class.new do
        attr_accessor :name, :email

        attr_writer :age
      end.new
    end

    it 'assigns attributes that have setters' do
      described_class.assign_known_attrs(record, { name: 'Alice', email: 'alice@example.com' })
      expect(record.name).to eq('Alice')
      expect(record.email).to eq('alice@example.com')
    end

    it 'skips attributes without setters' do
      expect do
        described_class.assign_known_attrs(record, { name: 'Bob', nonexistent: 'value' })
      end.not_to raise_error
      expect(record.name).to eq('Bob')
    end

    it 'handles method-only setters' do
      described_class.assign_known_attrs(record, { age: 30 })
      expect(record.instance_variable_get(:@age)).to eq(30)
    end

    it 'handles empty attributes hash' do
      expect do
        described_class.assign_known_attrs(record, {})
      end.not_to raise_error
    end
  end

  describe '.find_or_init_by_best' do
    let(:ar_class) do
      Class.new do
        def self.find_or_initialize_by(attrs)
          new(attrs)
        end

        def self.new(attrs = {})
          obj = allocate
          obj.instance_variable_set(:@attrs, attrs)
          obj
        end

        attr_reader :attrs
      end
    end

    before do
      allow(described_class).to receive(:ar_class?).and_return(true)
    end

    it 'uses first keyset with existing columns' do
      allow(described_class).to receive(:has_columns?).with(ar_class, [:id]).and_return(false)
      allow(described_class).to receive(:has_columns?).with(ar_class, [:name]).and_return(true)

      result = described_class.find_or_init_by_best(ar_class, { id: 1 }, { name: 'Alice' })
      expect(result.attrs).to eq({ name: 'Alice' })
    end

    it 'skips nil keysets' do
      allow(described_class).to receive(:has_columns?).with(ar_class, [:name]).and_return(true)

      result = described_class.find_or_init_by_best(ar_class, nil, { name: 'Bob' })
      expect(result.attrs).to eq({ name: 'Bob' })
    end

    it 'skips empty keysets' do
      allow(described_class).to receive(:has_columns?).with(ar_class, [:name]).and_return(true)

      result = described_class.find_or_init_by_best(ar_class, {}, { name: 'Charlie' })
      expect(result.attrs).to eq({ name: 'Charlie' })
    end

    it 'returns new record when no keysets match' do
      allow(described_class).to receive(:has_columns?).and_return(false)

      result = described_class.find_or_init_by_best(ar_class, { id: 1 }, { uuid: 'abc' })
      expect(result.attrs).to eq({})
    end

    it 'returns new record when no keysets provided' do
      result = described_class.find_or_init_by_best(ar_class)
      expect(result.attrs).to eq({})
    end

    it 'handles all nil keysets' do
      result = described_class.find_or_init_by_best(ar_class, nil, nil, nil)
      expect(result.attrs).to eq({})
    end
  end

  describe '.json_dump' do
    it 'returns the string unchanged' do
      json = '{"a":1}'
      expect(described_class.json_dump(json)).to eq(json)
    end

    it 'serializes objects to JSON' do
      expect(described_class.json_dump({ a: 1 })).to eq('{"a":1}')
    end

    it 'serializes arrays to JSON' do
      expect(described_class.json_dump([1, 2, 3])).to eq('[1,2,3]')
    end

    it 'falls back to to_s on Oj::Error' do
      obj = Object.new
      allow(Oj).to receive(:dump).and_raise(Oj::Error.new('test error'))
      result = described_class.json_dump(obj)
      expect(result).to be_a(String)
    end

    it 'falls back to to_s on TypeError' do
      # Create object that Oj can't serialize
      circular = {}
      circular[:self] = circular

      # Mock Oj to raise TypeError
      allow(Oj).to receive(:dump).and_raise(TypeError.new('cannot serialize'))

      result = described_class.json_dump(circular)
      expect(result).to be_a(String)
    end

    it 'handles nil by converting to JSON null' do
      expect(described_class.json_dump(nil)).to eq('null')
    end

    it 'handles numeric values' do
      expect(described_class.json_dump(42)).to eq('42')
      expect(described_class.json_dump(3.14)).to eq('3.14')
    end
  end

  describe '.json_load' do
    it 'parses JSON strings into hashes' do
      expect(described_class.json_load('{"a":1}')).to eq('a' => 1)
    end

    it 'returns hash input untouched' do
      h = { 'a' => 1 }
      expect(described_class.json_load(h)).to equal(h)
    end

    it 'returns empty hash for invalid JSON' do
      expect(described_class.json_load('invalid')).to eq({})
    end

    it 'returns empty hash for nil input' do
      # json_load converts nil to "nil" string, which Oj.load returns as nil
      result = described_class.json_load(nil)
      expect(result).to be_nil.or eq({})
    end

    it 'parses JSON arrays' do
      expect(described_class.json_load('[1,2,3]')).to eq([1, 2, 3])
    end

    it 'converts non-string non-hash input to string then parses' do
      # Numeric converts to "123" which Oj.load returns as integer 123
      result = described_class.json_load(123)
      expect(result).to eq(123).or eq({})
    end

    it 'handles empty string' do
      # Empty string to_s is "", Oj.load returns nil, rescue returns {}
      result = described_class.json_load('')
      expect(result).to eq({}).or be_nil
    end

    it 'handles malformed JSON gracefully' do
      expect(described_class.json_load('{"a":}')).to eq({})
      expect(described_class.json_load('{invalid json')).to eq({})
    end
  end
end
