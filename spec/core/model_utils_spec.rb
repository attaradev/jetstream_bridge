require 'jetstream_bridge/core/model_utils'

RSpec.describe JetstreamBridge::ModelUtils do
  describe '.json_dump' do
    it 'returns the string unchanged' do
      json = '{"a":1}'
      expect(described_class.json_dump(json)).to eq(json)
    end

    it 'serializes objects to JSON' do
      expect(described_class.json_dump({ a: 1 })).to eq('{"a":1}')
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
  end
end
