# frozen_string_literal: true

require 'jetstream_bridge/topology/subject_matcher'

RSpec.describe JetstreamBridge::SubjectMatcher do
  describe '.match?' do
    it 'matches exact subjects' do
      expect(described_class.match?('a.b', 'a.b')).to be true
      expect(described_class.match?('a.b', 'a.c')).to be false
    end

    it 'supports single-token wildcards' do
      expect(described_class.match?('a.*.c', 'a.b.c')).to be true
      expect(described_class.match?('a.*.c', 'a.b.d')).to be false
    end

    it 'requires * to consume exactly one token' do
      expect(described_class.match?('a.*', 'a')).to be false
      expect(described_class.match?('*', 'a.b')).to be false
    end

    it 'supports tail wildcards' do
      expect(described_class.match?('a.>', 'a.b.c')).to be true
      expect(described_class.match?('>', 'a.b.c')).to be true
      expect(described_class.match?('a.>', 'b.c')).to be false
    end
  end

  describe '.covered?' do
    it 'returns true when any pattern matches the subject' do
      patterns = %w[a.* b.>]
      expect(described_class.covered?(patterns, 'a.b')).to be true
      expect(described_class.covered?(patterns, 'b.c.d')).to be true
      expect(described_class.covered?(patterns, 'c')).to be false
    end
  end

  describe '.overlap?' do
    it 'detects overlapping wildcard patterns' do
      expect(described_class.overlap?('a.*.c', 'a.b.*')).to be true
      expect(described_class.overlap?('a.*.c', 'a.*.d')).to be false
      expect(described_class.overlap?('a.>', 'a')).to be true
      expect(described_class.overlap?('a.*', 'a')).to be false
    end

    context 'with tail wildcards' do
      it 'detects overlap when first pattern has >' do
        expect(described_class.overlap?('a.b.>', 'a.b.c')).to be true
        expect(described_class.overlap?('a.>', 'a.b.c.d')).to be true
      end

      it 'detects overlap when second pattern has >' do
        expect(described_class.overlap?('a.b.c', 'a.b.>')).to be true
        expect(described_class.overlap?('a.b.c.d', 'a.>')).to be true
      end

      it 'detects overlap with > in both patterns' do
        expect(described_class.overlap?('a.>', 'a.>')).to be true
        expect(described_class.overlap?('a.b.>', 'a.c.>')).to be false
      end

      it 'handles > at different positions' do
        expect(described_class.overlap?('a.>', 'a.b.>')).to be true
        expect(described_class.overlap?('a.b.>', 'a.>')).to be true
      end
    end

    context 'with * wildcards' do
      it 'detects overlap with * in both patterns' do
        expect(described_class.overlap?('a.*.c', 'a.*.c')).to be true
        expect(described_class.overlap?('a.*.c', 'a.b.*')).to be true
        expect(described_class.overlap?('*.b.c', 'a.*.c')).to be true
      end

      it 'handles multiple * wildcards' do
        expect(described_class.overlap?('*.*.c', 'a.*.c')).to be true
        expect(described_class.overlap?('a.*.*', 'a.b.*')).to be true
      end
    end

    context 'edge cases' do
      it 'handles empty tail arrays' do
        expect(described_class.overlap?('a', 'b')).to be false
        expect(described_class.overlap?('a', 'a')).to be true
      end

      it 'handles patterns longer than subject' do
        expect(described_class.overlap?('a.b.c.d', 'a.b')).to be false
        expect(described_class.overlap?('a.b', 'a.b.c.d')).to be false
      end

      it 'handles exact matches' do
        expect(described_class.overlap?('a.b.c', 'a.b.c')).to be true
      end
    end

    context 'with mixed wildcards' do
      it 'detects overlap between * and >' do
        expect(described_class.overlap?('a.*', 'a.>')).to be true
        expect(described_class.overlap?('a.>', 'a.*')).to be true
      end

      it 'detects overlap with complex patterns' do
        expect(described_class.overlap?('a.*.c.>', 'a.b.*')).to be true
        expect(described_class.overlap?('*.b.>', 'a.*.c')).to be true
      end
    end
  end
end
