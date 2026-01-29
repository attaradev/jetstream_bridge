# frozen_string_literal: true

require 'spec_helper'
require 'jetstream_bridge/consumer/consumer_state'

RSpec.describe JetstreamBridge::Consumer::ProcessingState do
  it 'initializes with provided backoff and iterations' do
    state = described_class.new(idle_backoff: 0.1, iterations: 5)
    expect(state.idle_backoff).to eq(0.1)
    expect(state.iterations).to eq(5)
  end
end

RSpec.describe JetstreamBridge::Consumer::LifecycleState do
  it 'tracks running and shutdown flags' do
    state = described_class.new(start_time: Time.now)
    expect(state.running).to be true
    expect(state.shutdown_requested).to be false

    state.stop!
    expect(state.running).to be false
    expect(state.shutdown_requested).to be true
  end

  it 'records signals and uptime' do
    now = Time.now
    state = described_class.new(start_time: now - 5)
    state.signal!('TERM')

    expect(state.signal_received).to eq('TERM')
    expect(state.running).to be false
    expect(state.uptime(now)).to be_within(0.1).of(5)
  end
end

RSpec.describe JetstreamBridge::Consumer::ConnectionState do
  it 'tracks reconnect attempts and health checks' do
    now = Time.now
    state = described_class.new(now: now - 10)
    expect(state.last_health_check).to be_within(0.1).of(now - 10)

    state.reconnect_attempts = 2
    state.mark_health_check(now)

    expect(state.reconnect_attempts).to eq(2)
    expect(state.last_health_check).to eq(now)
  end
end
