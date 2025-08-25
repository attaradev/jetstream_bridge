require 'jetstream_bridge'
require 'oj'

RSpec.describe JetstreamBridge::Publisher do
  let(:jts) { double('jetstream') }
  let(:ack) { double('ack', duplicate?: false, error: nil) }
  subject(:publisher) { described_class.new }

  before do
    JetstreamBridge.reset!
    JetstreamBridge.configure do |c|
      c.destination_app = 'dest'
      c.app_name        = 'source'
      c.env             = 'test'
    end
    allow(JetstreamBridge::Connection).to receive(:connect!).and_return(jts)
    allow(jts).to receive(:publish).and_return(ack)
  end

  after { JetstreamBridge.reset! }

  let(:payload) { { 'id' => '1', 'name' => 'Ada' } }

  it 'publishes with nats-msg-id header matching envelope event_id' do
    expect(jts).to receive(:publish) do |subject, data, header:|
      envelope = Oj.load(data, mode: :strict)
      expect(subject).to eq('test.source.sync.dest')
      expect(header['nats-msg-id']).to eq(envelope['event_id'])
      ack
    end

    expect(
      publisher.publish(resource_type: 'user', event_type: 'created', payload: payload)
    ).to be(true)
  end
end
