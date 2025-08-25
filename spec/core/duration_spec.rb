require 'jetstream_bridge/core/duration'

RSpec.describe JetstreamBridge::Duration do
  describe '.to_millis' do
    context 'with explicit unit' do
      it 'converts seconds to milliseconds' do
        expect(described_class.to_millis(2, default_unit: :s)).to eq(2_000)
      end

      it 'converts milliseconds to milliseconds without change' do
        expect(described_class.to_millis(2, default_unit: :ms)).to eq(2)
      end
    end

    context 'with auto unit' do
      it 'uses seconds for small integers' do
        expect(described_class.to_millis(2)).to eq(2_000)
      end

      it 'uses milliseconds for large integers' do
        expect(described_class.to_millis(1_500)).to eq(1_500)
      end
    end
  end
end
