# frozen_string_literal: true

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

    context 'with auto unit and numeric string' do
      it 'uses seconds for small integers' do
        expect(described_class.to_millis('2')).to eq(2_000)
      end

      it 'uses milliseconds for large integers' do
        expect(described_class.to_millis('1_500')).to eq(1_500)
      end
    end
  end

  describe '.normalize_list_to_millis' do
    it 'converts mixed durations into milliseconds' do
      list = ['1s', '500ms', 2]
      expect(described_class.normalize_list_to_millis(list)).to eq([1_000, 500, 2_000])
    end

    it 'returns an empty array for nil input' do
      expect(described_class.normalize_list_to_millis(nil)).to eq([])
    end
  end
end
