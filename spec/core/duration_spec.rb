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

      it 'converts nanoseconds to milliseconds' do
        expect(described_class.to_millis(1_500_000_000, default_unit: :ns)).to eq(1_500)
      end

      it 'converts microseconds to milliseconds' do
        expect(described_class.to_millis(1_500_000, default_unit: :us)).to eq(1_500)
      end

      it 'converts minutes to milliseconds' do
        expect(described_class.to_millis(2, default_unit: :m)).to eq(120_000)
      end

      it 'converts hours to milliseconds' do
        expect(described_class.to_millis(1, default_unit: :h)).to eq(3_600_000)
      end

      it 'converts days to milliseconds' do
        expect(described_class.to_millis(1, default_unit: :d)).to eq(86_400_000)
      end

      it 'raises error for invalid default_unit' do
        expect do
          described_class.to_millis(100, default_unit: :invalid)
        end.to raise_error(ArgumentError, /invalid unit for default_unit/)
      end
    end

    context 'with auto unit' do
      it 'uses seconds for small integers' do
        expect(described_class.to_millis(2)).to eq(2_000)
      end

      it 'uses milliseconds for large integers' do
        expect(described_class.to_millis(1_500)).to eq(1_500)
      end

      it 'treats 1000 as milliseconds' do
        expect(described_class.to_millis(1_000)).to eq(1_000)
      end

      it 'treats 999 as seconds' do
        expect(described_class.to_millis(999)).to eq(999_000)
      end
    end

    context 'with Float values' do
      it 'converts float seconds to milliseconds' do
        expect(described_class.to_millis(2.5, default_unit: :s)).to eq(2_500)
      end

      it 'uses auto unit heuristic for small floats' do
        expect(described_class.to_millis(5.5)).to eq(5_500)
      end

      it 'uses auto unit heuristic for large floats' do
        expect(described_class.to_millis(1500.5)).to eq(1_501)
      end

      it 'handles fractional milliseconds' do
        expect(described_class.to_millis(100.75, default_unit: :ms)).to eq(101)
      end
    end

    context 'with String values containing units' do
      it 'parses seconds' do
        expect(described_class.to_millis('30s')).to eq(30_000)
      end

      it 'parses milliseconds' do
        expect(described_class.to_millis('500ms')).to eq(500)
      end

      it 'parses nanoseconds' do
        expect(described_class.to_millis('250ns')).to eq(0)
      end

      it 'parses microseconds' do
        expect(described_class.to_millis('250us')).to eq(0)
      end

      it 'parses microseconds with alternate symbol' do
        expect(described_class.to_millis('250µs')).to eq(0)
      end

      it 'parses minutes' do
        expect(described_class.to_millis('5m')).to eq(300_000)
      end

      it 'parses hours' do
        expect(described_class.to_millis('1h')).to eq(3_600_000)
      end

      it 'parses days' do
        expect(described_class.to_millis('2d')).to eq(172_800_000)
      end

      it 'handles decimal values in strings' do
        expect(described_class.to_millis('2.5s')).to eq(2_500)
      end

      it 'handles underscores in numeric strings' do
        expect(described_class.to_millis('1_000ms')).to eq(1_000)
      end

      it 'handles whitespace between number and unit' do
        expect(described_class.to_millis('30 s')).to eq(30_000)
      end

      it 'is case-insensitive for units' do
        expect(described_class.to_millis('30S')).to eq(30_000)
        expect(described_class.to_millis('500MS')).to eq(500)
      end

      it 'raises error for invalid string format' do
        expect do
          described_class.to_millis('invalid')
        end.to raise_error(ArgumentError, /invalid duration/)
      end

      it 'raises error for string with invalid unit' do
        expect do
          described_class.to_millis('30x')
        end.to raise_error(ArgumentError, /invalid duration/)
      end
    end

    context 'with auto unit and numeric string' do
      it 'uses seconds for small integers' do
        expect(described_class.to_millis('2')).to eq(2_000)
      end

      it 'uses milliseconds for large integers' do
        expect(described_class.to_millis('1_500')).to eq(1_500)
      end

      it 'handles strings with explicit unit override' do
        expect(described_class.to_millis('2', default_unit: :ms)).to eq(2)
      end
    end

    context 'with objects responding to to_f' do
      it 'converts object with to_f to milliseconds' do
        obj = Struct.new(:val).new(2.5)
        def obj.to_f
          val
        end
        expect(described_class.to_millis(obj, default_unit: :s)).to eq(2_500)
      end

      it 'raises error for objects without to_f' do
        obj = Object.new
        expect do
          described_class.to_millis(obj)
        end.to raise_error(ArgumentError, /invalid duration type/)
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

    it 'returns an empty array for empty array' do
      expect(described_class.normalize_list_to_millis([])).to eq([])
    end

    it 'handles single value' do
      expect(described_class.normalize_list_to_millis(5)).to eq([5_000])
    end

    it 'respects default_unit parameter' do
      list = [100, 200, 300]
      expect(described_class.normalize_list_to_millis(list, default_unit: :ms)).to eq([100, 200, 300])
    end

    it 'converts complex list with various formats' do
      list = ['1h', 1500, '30s', 1.5]
      expect(described_class.normalize_list_to_millis(list)).to eq([3_600_000, 1_500, 30_000, 1_500])
    end
  end
end
