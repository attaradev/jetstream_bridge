# frozen_string_literal: true

require 'jetstream_bridge'

RSpec.describe JetstreamBridge::Models::PublishResult do
  describe 'successful result' do
    subject(:result) do
      described_class.new(
        success: true,
        event_id: 'evt-123',
        subject: 'app.sync.worker',
        duplicate: false
      )
    end

    it 'returns true for success?' do
      expect(result.success?).to be(true)
    end

    it 'returns false for failure?' do
      expect(result.failure?).to be(false)
    end

    it 'returns false for duplicate?' do
      expect(result.duplicate?).to be(false)
    end

    it 'exposes event_id' do
      expect(result.event_id).to eq('evt-123')
    end

    it 'exposes subject' do
      expect(result.subject).to eq('app.sync.worker')
    end

    it 'has nil error' do
      expect(result.error).to be_nil
    end

    it 'is frozen' do
      expect(result).to be_frozen
    end
  end

  describe 'failed result' do
    let(:error) { StandardError.new('Connection failed') }

    subject(:result) do
      described_class.new(
        success: false,
        event_id: 'evt-456',
        subject: 'app.sync.worker',
        error: error
      )
    end

    it 'returns false for success?' do
      expect(result.success?).to be(false)
    end

    it 'returns true for failure?' do
      expect(result.failure?).to be(true)
    end

    it 'exposes error' do
      expect(result.error).to eq(error)
    end

    it 'exposes event_id' do
      expect(result.event_id).to eq('evt-456')
    end

    it 'is frozen' do
      expect(result).to be_frozen
    end
  end

  describe 'duplicate result' do
    subject(:result) do
      described_class.new(
        success: true,
        event_id: 'evt-789',
        subject: 'app.sync.worker',
        duplicate: true
      )
    end

    it 'returns true for duplicate?' do
      expect(result.duplicate?).to be(true)
    end

    it 'returns true for success?' do
      expect(result.success?).to be(true)
    end
  end

  describe 'immutability' do
    subject(:result) do
      described_class.new(
        success: true,
        event_id: 'evt-immutable',
        subject: 'test.subject'
      )
    end

    it 'cannot modify event_id' do
      expect { result.instance_variable_set(:@event_id, 'changed') }.to raise_error(FrozenError)
    end
  end

  describe '#to_h' do
    context 'with successful result and no error' do
      subject(:result) do
        described_class.new(
          success: true,
          event_id: 'evt-success',
          subject: 'test.subject',
          duplicate: false
        )
      end

      it 'returns hash with nil error' do
        hash = result.to_h
        expect(hash).to eq({
                             success: true,
                             event_id: 'evt-success',
                             subject: 'test.subject',
                             duplicate: false,
                             error: nil
                           })
      end
    end

    context 'with failed result and error' do
      let(:error) { StandardError.new('Connection timeout') }

      subject(:result) do
        described_class.new(
          success: false,
          event_id: 'evt-failed',
          subject: 'test.subject',
          error: error,
          duplicate: false
        )
      end

      it 'returns hash with error message' do
        hash = result.to_h
        expect(hash).to eq({
                             success: false,
                             event_id: 'evt-failed',
                             subject: 'test.subject',
                             duplicate: false,
                             error: 'Connection timeout'
                           })
      end
    end

    context 'with duplicate result' do
      subject(:result) do
        described_class.new(
          success: true,
          event_id: 'evt-duplicate',
          subject: 'test.subject',
          duplicate: true
        )
      end

      it 'returns hash with duplicate flag' do
        hash = result.to_h
        expect(hash[:duplicate]).to be true
      end
    end
  end

  describe '#to_hash' do
    it 'is an alias for to_h' do
      result = described_class.new(
        success: true,
        event_id: 'evt-alias',
        subject: 'test.subject'
      )

      expect(result.to_hash).to eq(result.to_h)
    end
  end

  describe '#inspect' do
    it 'returns readable string representation' do
      result = described_class.new(
        success: true,
        event_id: 'evt-inspect',
        subject: 'test.subject',
        duplicate: false
      )

      expect(result.inspect).to match(
        /PublishResult success=true event_id=evt-inspect duplicate=false/
      )
    end

    it 'shows duplicate flag when true' do
      result = described_class.new(
        success: true,
        event_id: 'evt-dup',
        subject: 'test.subject',
        duplicate: true
      )

      expect(result.inspect).to include('duplicate=true')
    end
  end
end
