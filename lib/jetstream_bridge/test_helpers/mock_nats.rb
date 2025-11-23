# frozen_string_literal: true

module JetstreamBridge
  module TestHelpers
    # In-memory mock for NATS JetStream connection
    # Simulates the NATS::IO::Client and JetStream API without requiring a real server
    module MockNats
      class MockConnection
        attr_reader :connected_at, :callbacks

        def initialize
          @connected = false
          @connected_at = nil
          @callbacks = { reconnect: [], disconnect: [], error: [] }
          # Use global storage to ensure persistence across test helper calls
          @jetstream = MockJetStream.new(MockNats.storage)
        end

        def connect(_urls = nil, **_options)
          @connected = true
          @connected_at = Time.now
          self
        end

        def jetstream
          raise NATS::IO::NoRespondersError, 'JetStream not available' unless @connected

          @jetstream
        end

        def connected?
          @connected
        end

        def on_reconnect(&block)
          @callbacks[:reconnect] << block if block
        end

        def on_disconnect(&block)
          @callbacks[:disconnect] << block if block
        end

        def on_error(&block)
          @callbacks[:error] << block if block
        end

        def rtt
          0.001 # 1ms simulated round-trip time
        end

        # Simulate JetStream API requests
        # Used by overlap_guard.rb for stream management operations
        def request(subject, payload, timeout: 1)
          raise NATS::IO::NoRespondersError, 'Not connected' unless @connected

          # Parse the API request
          response_data = case subject
                          when '$JS.API.STREAM.NAMES'
                            # Return list of stream names
                            stream_names = @jetstream.storage.streams.keys.map { |name| { 'name' => name } }
                            {
                              'type' => 'io.nats.jetstream.api.v1.stream_names_response',
                              'total' => stream_names.size,
                              'offset' => 0,
                              'limit' => 1024,
                              'streams' => stream_names
                            }
                          when /^\$JS\.API\.STREAM\.INFO\.(.+)$/
                            # Return stream info for specific stream
                            stream_name = ::Regexp.last_match(1)
                            stream = @jetstream.storage.find_stream(stream_name)
                            if stream
                              info = stream.info
                              {
                                'type' => 'io.nats.jetstream.api.v1.stream_info_response',
                                'config' => {
                                  'name' => info.config.name,
                                  'subjects' => info.config.subjects
                                }
                              }
                            else
                              {
                                'error' => {
                                  'code' => 404,
                                  'description' => 'stream not found'
                                }
                              }
                            end
                          else
                            # Generic response for unknown API calls
                            { 'type' => 'io.nats.jetstream.api.v1.response' }
                          end

          # Return a mock message object with the response data
          MockApiResponse.new(Oj.dump(response_data, mode: :compat))
        end

        def close
          @connected = false
          @callbacks[:disconnect].each(&:call)
        end

        # Test helpers for simulating connection events
        def simulate_disconnect!
          @connected = false
          @callbacks[:disconnect].each(&:call)
        end

        def simulate_reconnect!
          @connected = true
          @callbacks[:reconnect].each(&:call)
        end

        def simulate_error!(error)
          @callbacks[:error].each { |cb| cb.call(error) }
        end
      end

      class MockJetStream
        attr_reader :storage

        def initialize(storage = nil)
          @storage = storage || MockNats.storage
        end

        def account_info
          OpenStruct.new(
            memory: 1024 * 1024 * 100,
            storage: 1024 * 1024 * 1000,
            streams: @storage.streams.count,
            consumers: @storage.consumers.count
          )
        end

        def publish(subject, data, header: {})
          @storage.publish(subject, data, header)
        end

        def pull_subscribe(subject, durable_name, **options)
          @storage.create_subscription(subject, durable_name, options)
        end

        def consumer_info(stream_name, durable_name)
          consumer = @storage.find_consumer(stream_name, durable_name)
          raise NATS::JetStream::Error, 'consumer not found' unless consumer

          consumer.info
        end

        def stream_info(stream_name)
          stream = @storage.find_stream(stream_name)
          raise NATS::JetStream::Error, 'stream not found' unless stream

          stream.info
        end

        def add_stream(config)
          @storage.add_stream(config)
        end

        def delete_stream(name)
          @storage.delete_stream(name)
        end

        def add_consumer(stream_name, **config)
          @storage.add_consumer(stream_name, config)
        end

        def delete_consumer(stream_name, consumer_name)
          @storage.delete_consumer(stream_name, consumer_name)
        end
      end

      class InMemoryStorage
        attr_reader :streams, :consumers, :messages, :subscriptions

        def initialize
          @streams = {}
          @consumers = {}
          @messages = []
          @subscriptions = {}
          @sequence_counter = 0
          @mutex = Mutex.new
        end

        def publish(subject, data, header)
          @mutex.synchronize do
            event_id = header['nats-msg-id'] || SecureRandom.uuid

            # Check for duplicate
            duplicate = @messages.any? { |msg| msg[:header]['nats-msg-id'] == event_id }

            unless duplicate
              @sequence_counter += 1
              @messages << {
                subject: subject,
                data: data,
                header: header,
                sequence: @sequence_counter,
                timestamp: Time.now,
                delivery_count: 0
              }
            end

            MockAck.new(
              duplicate: duplicate,
              sequence: @sequence_counter,
              stream: find_stream_for_subject(subject)&.name || 'mock-stream'
            )
          end
        end

        def create_subscription(subject, durable_name, options)
          @mutex.synchronize do
            stream_name = options[:stream] || find_stream_for_subject(subject)&.name || 'mock-stream'

            subscription = MockSubscription.new(
              subject: subject,
              durable_name: durable_name,
              storage: self,
              stream_name: stream_name,
              options: options
            )

            @subscriptions[durable_name] = subscription

            # Register consumer
            @consumers[durable_name] = MockConsumer.new(
              name: durable_name,
              stream: stream_name,
              config: options
            )

            subscription
          end
        end

        def fetch_messages(subject, durable_name, batch_size, _timeout)
          @mutex.synchronize do
            consumer = @consumers[durable_name]
            stream_name = consumer&.stream || 'mock-stream'

            # Find messages matching the subject
            matching = @messages.select do |msg|
              msg[:subject] == subject && msg[:delivery_count] < max_deliver_for(durable_name)
            end

            # Take up to batch_size messages
            to_deliver = matching.first(batch_size)

            # Increment delivery count and return MockMessage objects
            to_deliver.map do |msg|
              msg[:delivery_count] += 1

              MockMessage.new(
                subject: msg[:subject],
                data: msg[:data],
                header: msg[:header],
                sequence: msg[:sequence],
                stream: stream_name,
                consumer: durable_name,
                num_delivered: msg[:delivery_count],
                storage: self,
                message_ref: msg
              )
            end
          end
        end

        def ack_message(message_ref)
          @mutex.synchronize do
            @messages.delete(message_ref)
          end
        end

        def nak_message(_message_ref, delay: nil)
          @mutex.synchronize do
            # Message stays in queue for redelivery
            # Note: delivery_count was already incremented during fetch
            # We don't decrement it here as it represents actual delivery attempts
          end
        end

        def term_message(message_ref)
          @mutex.synchronize do
            @messages.delete(message_ref)
          end
        end

        def add_stream(config)
          @mutex.synchronize do
            name = config[:name] || config['name']
            @streams[name] = MockStream.new(name, config)
          end
        end

        def delete_stream(name)
          @mutex.synchronize do
            @streams.delete(name)
          end
        end

        def find_stream(name)
          @streams[name]
        end

        def find_stream_for_subject(_subject)
          @streams.values.first # Simplified: return first stream
        end

        def find_consumer(stream_name, durable_name)
          consumer = @consumers[durable_name]
          return nil unless consumer
          return nil unless consumer.stream == stream_name

          consumer
        end

        def add_consumer(stream_name, config)
          @mutex.synchronize do
            durable_name = config[:durable_name] || config['durable_name']
            @consumers[durable_name] = MockConsumer.new(
              name: durable_name,
              stream: stream_name,
              config: config
            )
          end
        end

        def delete_consumer(stream_name, consumer_name)
          @mutex.synchronize do
            consumer = @consumers[consumer_name]
            @consumers.delete(consumer_name) if consumer&.stream == stream_name
          end
        end

        def reset!
          @mutex.synchronize do
            @streams.clear
            @consumers.clear
            @messages.clear
            @subscriptions.clear
            @sequence_counter = 0
          end
        end

        private

        def max_deliver_for(durable_name)
          consumer = @consumers[durable_name]
          return 5 unless consumer # Default

          consumer.config[:max_deliver] || consumer.config['max_deliver'] || 5
        end
      end

      class MockAck
        attr_reader :sequence, :stream, :error

        def initialize(duplicate:, sequence:, stream:)
          @duplicate = duplicate
          @sequence = sequence
          @stream = stream
          @error = nil
        end

        def duplicate?
          @duplicate
        end
      end

      class MockMessage
        attr_reader :subject, :data, :header, :sequence, :stream, :consumer, :num_delivered

        def initialize(subject:, data:, header:, sequence:, stream:, consumer:, num_delivered:, storage:, message_ref:)
          @subject = subject
          @data = data
          @header = header
          @sequence = sequence
          @stream = stream
          @consumer = consumer
          @num_delivered = num_delivered
          @storage = storage
          @message_ref = message_ref
        end

        def metadata
          OpenStruct.new(
            sequence: OpenStruct.new(stream: @sequence, consumer: @sequence),
            num_delivered: @num_delivered,
            stream: @stream,
            consumer: @consumer,
            timestamp: Time.now
          )
        end

        def ack
          @storage.ack_message(@message_ref)
        end

        def nak(in_progress_duration: nil)
          @storage.nak_message(@message_ref, delay: in_progress_duration)
        end

        def term
          @storage.term_message(@message_ref)
        end
      end

      class MockSubscription
        attr_reader :subject, :durable_name, :stream_name

        def initialize(subject:, durable_name:, storage:, stream_name:, options:)
          @subject = subject
          @durable_name = durable_name
          @storage = storage
          @stream_name = stream_name
          @options = options
          @unsubscribed = false
        end

        def fetch(batch_size, timeout: 5)
          raise NATS::JetStream::Error, 'consumer not found' if @unsubscribed

          @storage.fetch_messages(@subject, @durable_name, batch_size, timeout)
        rescue StandardError => e
          raise NATS::IO::Timeout if timeout && e.is_a?(Timeout::Error)

          raise
        end

        def unsubscribe
          @unsubscribed = true
        end
      end

      class MockStream
        attr_reader :name, :config

        def initialize(name, config)
          @name = name
          @config = config
        end

        def info
          OpenStruct.new(
            config: OpenStruct.new(
              name: @name,
              subjects: @config[:subjects] || [@name],
              retention: @config[:retention] || 'limits',
              max_consumers: @config[:max_consumers] || -1,
              max_msgs: @config[:max_msgs] || -1,
              max_bytes: @config[:max_bytes] || -1,
              discard: @config[:discard] || 'old',
              max_age: @config[:max_age] || 0,
              max_msgs_per_subject: @config[:max_msgs_per_subject] || -1,
              max_msg_size: @config[:max_msg_size] || -1,
              storage: @config[:storage] || 'file',
              num_replicas: @config[:num_replicas] || 1
            ),
            state: OpenStruct.new(
              messages: 0,
              bytes: 0,
              first_seq: 1,
              last_seq: 0,
              consumer_count: 0
            )
          )
        end
      end

      class MockConsumer
        attr_reader :name, :stream, :config

        def initialize(name:, stream:, config:)
          @name = name
          @stream = stream
          @config = config
        end

        def info
          OpenStruct.new(
            name: @name,
            stream_name: @stream,
            config: OpenStruct.new(
              durable_name: @name,
              ack_policy: @config[:ack_policy] || 'explicit',
              max_deliver: @config[:max_deliver] || 5,
              ack_wait: @config[:ack_wait] || 30_000_000_000,
              filter_subject: @config[:filter_subject] || '',
              replay_policy: @config[:replay_policy] || 'instant'
            ),
            num_pending: 0,
            num_delivered: 0
          )
        end
      end

      # Mock API response message
      # Simulates NATS::Msg for JetStream API responses
      class MockApiResponse
        attr_reader :data

        def initialize(data)
          @data = data
        end
      end

      # Factory method to create a mock connection
      def self.create_mock_connection
        MockConnection.new
      end

      # Global storage accessor for testing
      def self.storage
        @storage ||= InMemoryStorage.new
      end

      def self.reset!
        @storage&.reset!
      end
    end
  end
end
