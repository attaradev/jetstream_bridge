# frozen_string_literal: true

require 'jetstream_bridge'
require 'oj'

RSpec.describe JetstreamBridge::InboxMessage do
  let(:metadata) do
    double('metadata',
           stream_sequence: 1,
           num_delivered: 2,
           stream: 'test',
           consumer: 'durable')
  end

  let(:nats_msg) do
    double('nats-msg',
           subject: 'inbox.subject',
           data: Oj.dump({ 'foo' => 'bar' }),
           header: { 'nats-msg-id' => 'id-123' },
           metadata: metadata,
           ack: nil,
           nak: nil)
  end

  subject(:msg) { described_class.from_nats(nats_msg) }

  it 'delegates ack to the underlying message' do
    expect(nats_msg).to receive(:ack)
    msg.ack
  end

  it 'delegates nak to the underlying message' do
    expect(nats_msg).to receive(:nak).with(:foo)
    msg.nak(:foo)
  end

  describe '.from_nats' do
    context 'with complete NATS message' do
      it 'extracts all metadata fields' do
        expect(msg.seq).to eq(1)
        expect(msg.deliveries).to eq(2)
        expect(msg.stream).to eq('test')
        expect(msg.subject).to eq('inbox.subject')
      end

      it 'parses JSON body' do
        expect(msg.body).to eq({ 'foo' => 'bar' })
      end

      it 'extracts event_id from header' do
        expect(msg.event_id).to eq('id-123')
      end

      it 'stores raw data' do
        expect(msg.raw).to eq(Oj.dump({ 'foo' => 'bar' }))
      end

      it 'normalizes header keys to lowercase' do
        expect(msg.headers).to have_key('nats-msg-id')
        expect(msg.headers['nats-msg-id']).to eq('id-123')
      end
    end

    context 'when msg.metadata is nil' do
      let(:nats_msg_no_metadata) do
        double('nats-msg',
               subject: 'inbox.subject',
               data: Oj.dump({ 'foo' => 'bar' }),
               header: { 'nats-msg-id' => 'id-123' },
               metadata: nil,
               ack: nil,
               nak: nil)
      end

      it 'sets metadata fields to nil' do
        msg = described_class.from_nats(nats_msg_no_metadata)
        expect(msg.seq).to be_nil
        expect(msg.deliveries).to be_nil
        expect(msg.stream).to be_nil
      end

      it 'still extracts event_id from header' do
        msg = described_class.from_nats(nats_msg_no_metadata)
        expect(msg.event_id).to eq('id-123')
      end
    end

    context 'when msg does not respond_to :metadata' do
      let(:nats_msg_no_respond) do
        msg_double = double('nats-msg',
                            subject: 'inbox.subject',
                            data: Oj.dump({ 'foo' => 'bar' }),
                            header: { 'nats-msg-id' => 'id-456' },
                            ack: nil,
                            nak: nil)
        allow(msg_double).to receive(:respond_to?).with(:metadata).and_return(false)
        allow(msg_double).to receive(:respond_to?).with(:ack).and_return(true)
        allow(msg_double).to receive(:respond_to?).with(:nak).and_return(true)
        msg_double
      end

      it 'sets metadata fields to nil' do
        msg = described_class.from_nats(nats_msg_no_respond)
        expect(msg.seq).to be_nil
        expect(msg.deliveries).to be_nil
        expect(msg.stream).to be_nil
      end
    end

    context 'when msg.header is nil' do
      let(:nats_msg_no_header) do
        double('nats-msg',
               subject: 'inbox.subject',
               data: Oj.dump({ 'event_id' => 'evt-from-body' }),
               header: nil,
               metadata: metadata,
               ack: nil,
               nak: nil)
      end

      it 'uses empty hash for headers' do
        msg = described_class.from_nats(nats_msg_no_header)
        expect(msg.headers).to eq({})
      end

      it 'extracts event_id from body' do
        msg = described_class.from_nats(nats_msg_no_header)
        expect(msg.event_id).to eq('evt-from-body')
      end
    end

    context 'when event_id is missing from header and body' do
      let(:nats_msg_no_id) do
        double('nats-msg',
               subject: 'inbox.subject',
               data: Oj.dump({ 'foo' => 'bar' }),
               header: {},
               metadata: metadata,
               ack: nil,
               nak: nil)
      end

      it 'generates event_id from sequence' do
        msg = described_class.from_nats(nats_msg_no_id)
        expect(msg.event_id).to eq('seq:1')
      end
    end

    context 'when event_id and seq are both missing' do
      let(:metadata_no_seq) do
        double('metadata',
               stream_sequence: nil,
               num_delivered: 1,
               stream: 'test',
               consumer: 'durable')
      end

      let(:nats_msg_no_id_no_seq) do
        double('nats-msg',
               subject: 'inbox.subject',
               data: Oj.dump({ 'foo' => 'bar' }),
               header: {},
               metadata: metadata_no_seq,
               ack: nil,
               nak: nil)
      end

      it 'generates UUID event_id' do
        msg = described_class.from_nats(nats_msg_no_id_no_seq)
        expect(msg.event_id).to match(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/)
      end
    end

    context 'when event_id in header is whitespace' do
      let(:nats_msg_whitespace_id) do
        double('nats-msg',
               subject: 'inbox.subject',
               data: Oj.dump({ 'foo' => 'bar' }),
               header: { 'nats-msg-id' => '   ' },
               metadata: metadata,
               ack: nil,
               nak: nil)
      end

      it 'generates event_id from sequence after stripping' do
        msg = described_class.from_nats(nats_msg_whitespace_id)
        expect(msg.event_id).to eq('seq:1')
      end
    end

    context 'when data is invalid JSON' do
      let(:nats_msg_invalid_json) do
        double('nats-msg',
               subject: 'inbox.subject',
               data: 'not valid json',
               header: { 'nats-msg-id' => 'id-789' },
               metadata: metadata,
               ack: nil,
               nak: nil)
      end

      it 'sets body to empty hash' do
        msg = described_class.from_nats(nats_msg_invalid_json)
        expect(msg.body).to eq({})
      end

      it 'preserves raw data' do
        msg = described_class.from_nats(nats_msg_invalid_json)
        expect(msg.raw).to eq('not valid json')
      end
    end

    context 'when header keys are mixed case' do
      let(:nats_msg_mixed_case) do
        double('nats-msg',
               subject: 'inbox.subject',
               data: Oj.dump({ 'foo' => 'bar' }),
               header: { 'NATS-Msg-ID' => 'id-upper', 'Content-Type' => 'application/json' },
               metadata: metadata,
               ack: nil,
               nak: nil)
      end

      it 'normalizes all header keys to lowercase' do
        msg = described_class.from_nats(nats_msg_mixed_case)
        expect(msg.headers).to eq({
                                    'nats-msg-id' => 'id-upper',
                                    'content-type' => 'application/json'
                                  })
      end
    end

    context 'when metadata fields do not respond to methods' do
      let(:partial_metadata) do
        metadata_obj = double('metadata')
        allow(metadata_obj).to receive(:respond_to?).with(:stream_sequence).and_return(false)
        allow(metadata_obj).to receive(:respond_to?).with(:num_delivered).and_return(false)
        allow(metadata_obj).to receive(:respond_to?).with(:stream).and_return(true)
        allow(metadata_obj).to receive(:stream).and_return('partial-stream')
        allow(metadata_obj).to receive(:respond_to?).with(:consumer).and_return(false)
        metadata_obj
      end

      let(:nats_msg_partial_metadata) do
        double('nats-msg',
               subject: 'inbox.subject',
               data: Oj.dump({ 'event_id' => 'evt-partial' }),
               header: {},
               metadata: partial_metadata,
               ack: nil,
               nak: nil)
      end

      it 'sets missing fields to nil and extracts available fields' do
        msg = described_class.from_nats(nats_msg_partial_metadata)
        expect(msg.seq).to be_nil
        expect(msg.deliveries).to be_nil
        expect(msg.stream).to eq('partial-stream')
      end
    end
  end

  describe '#body_for_store' do
    context 'when body is not empty' do
      it 'returns parsed body' do
        expect(msg.body_for_store).to eq({ 'foo' => 'bar' })
      end
    end

    context 'when body is empty' do
      let(:nats_msg_empty_body) do
        double('nats-msg',
               subject: 'inbox.subject',
               data: 'raw data',
               header: { 'nats-msg-id' => 'id-empty' },
               metadata: metadata,
               ack: nil,
               nak: nil)
      end

      it 'returns raw data' do
        # Invalid JSON results in empty body
        msg = described_class.from_nats(nats_msg_empty_body)
        expect(msg.body_for_store).to eq('raw data')
      end
    end
  end

  describe '#data' do
    it 'returns raw data' do
      expect(msg.data).to eq(msg.raw)
    end
  end

  describe '#header' do
    it 'returns headers hash' do
      expect(msg.header).to eq(msg.headers)
    end
  end

  describe '#metadata' do
    it 'returns metadata struct with all fields' do
      metadata = msg.metadata
      expect(metadata.num_delivered).to eq(2)
      expect(metadata.sequence).to eq(1)
      expect(metadata.consumer).to eq('durable')
      expect(metadata.stream).to eq('test')
    end

    it 'memoizes metadata struct' do
      metadata1 = msg.metadata
      metadata2 = msg.metadata
      expect(metadata1).to be(metadata2)
    end
  end

  describe 'ack/nak with non-responding msg' do
    let(:simple_msg) do
      double('simple-msg',
             subject: 'inbox.subject',
             data: Oj.dump({ 'foo' => 'bar' }),
             header: { 'nats-msg-id' => 'id-123' },
             metadata: metadata)
    end

    before do
      allow(simple_msg).to receive(:respond_to?).with(:metadata).and_return(true)
      allow(simple_msg).to receive(:respond_to?).with(:ack).and_return(false)
      allow(simple_msg).to receive(:respond_to?).with(:nak).and_return(false)
    end

    it 'does not call ack when msg does not respond to it' do
      msg = described_class.from_nats(simple_msg)
      expect { msg.ack }.not_to raise_error
    end

    it 'does not call nak when msg does not respond to it' do
      msg = described_class.from_nats(simple_msg)
      expect { msg.nak }.not_to raise_error
    end
  end
end
