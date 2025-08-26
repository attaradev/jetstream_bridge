# frozen_string_literal: true

require 'jetstream_bridge/topology/stream'

RSpec.describe JetstreamBridge::StreamSupport do
  describe '.normalize_subjects' do
    it 'flattens, stringifies and removes blanks' do
      list = ['a', ['b', nil, ''], :c, 'a']
      expect(described_class.normalize_subjects(list)).to eq(%w[a b c])
    end

    it 'returns empty array for nil input' do
      expect(described_class.normalize_subjects(nil)).to eq([])
    end
  end

  describe '.missing_subjects' do
    it 'returns subjects not covered by existing patterns' do
      existing = ['a.*', 'b.>']
      desired  = ['a.b', 'b.c.d', 'c']
      expect(described_class.missing_subjects(existing, desired)).to eq(['c'])
    end
  end

  describe '.stream_not_found?' do
    it 'detects stream not found errors by message' do
      err1 = double('err', message: 'Stream Not Found')
      err2 = double('err', message: '404')
      err3 = double('err', message: 'other')
      expect(described_class.stream_not_found?(err1)).to be_truthy
      expect(described_class.stream_not_found?(err2)).to be_truthy
      expect(described_class.stream_not_found?(err3)).to be_falsey
    end
  end

  describe '.overlap_error?' do
    it 'detects overlap errors by message' do
      err1 = double('err', message: 'Subjects overlap')
      err2 = double('err', message: 'err_code=10065')
      err3 = double('err', message: '400')
      err4 = double('err', message: 'other')
      expect(described_class.overlap_error?(err1)).to be_truthy
      expect(described_class.overlap_error?(err2)).to be_truthy
      expect(described_class.overlap_error?(err3)).to be_truthy
      expect(described_class.overlap_error?(err4)).to be_falsey
    end
  end
end
