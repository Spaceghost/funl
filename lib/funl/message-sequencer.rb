require 'logger'
require 'funl/stream'
require 'funl/message'
require 'funl/blobber'

module Funl
  # Assigns a unique sequential ids to each message and relays it to its
  # destinations.
  class MessageSequencer
    include Funl::Stream

    attr_reader :server
    attr_reader :server_thread
    attr_reader :tick
    attr_reader :log
    attr_reader :stream_type
    attr_reader :message_class
    attr_reader :blob_type
    attr_reader :greeting
    attr_reader :subscribers

    def self.new *a
      if self == MessageSequencer
        require 'funl/message-sequencer-select'
        MessageSequencerSelect.new *a ###
      else
        super
      end
    end
    
    def initialize server, *conns, log: Logger.new($stderr),
        stream_type: ObjectStream::MSGPACK_TYPE,
        message_class: Message,
        blob_type: Blobber::MSGPACK_TYPE,
        tick: 0

      @server = server
      @log = log
      @stream_type = stream_type
      @message_class = message_class
      @blob_type = blob_type
      @greeting = default_greeting
      @tick = tick

      init_selector

      conns.each do |conn|
        try_conn conn
      end
      
      @subscribers_to_all = [] # [conn, ...]
      @subscribers = Hash.new {|h, tag| h[tag] = []} # tag => [conn, ...]
      @tags = Hash.new {|h, conn| h[conn] = []} # conn => [tag, ...]
    end

    def default_greeting
      {
        "blob" => blob_type
      }.freeze # can't change after initial conns read it
    end

    def start
      @server_thread = Thread.new do
        run
      end
    end

    def stop
      server_thread.kill if server_thread
    end

    def wait
      server_thread.join
    end

    def handle_control stream, op_type, tags = nil
      log.debug {"#{stream.peer_name} #{op_type} #{tags}"}

      case op_type
      when SUBSCRIBE_ALL
        @subscribers_to_all |= [stream]
      
      when SUBSCRIBE
        tags.each do |tag|
          @subscribers[tag] |= [stream]
        end
        @tags[stream] |= tags

      when UNSUBSCRIBE_ALL
        @subscribers_to_all.delete stream

      when UNSUBSCRIBE
        tags.each do |tag|
          @subscribers[tag].delete stream
        end
        @tags[stream] -= tags

      else
        log.error "bad operation: #{op_type.inspect}"
        return
      end

      ack = Message.control(op_type, tags)
      ack.global_tick = tick
      write_succeeds?(ack, stream)
    end

    def handle_message msg, origin_conn
      log.debug {"handling message #{msg.inspect}"}

      @tick += 1
      msg.global_tick = tick
      msg.delta = nil

      tags = msg.tags
      reflect = false
      dest_streams =
        if !tags or (tags.empty? rescue true)
          @subscribers_to_all.dup
        else
          reflect = tags.delete(true)
          tags.inject(@subscribers_to_all) {|a,tag| a + @subscribers[tag]}
        end

      if reflect
        log.debug {"reflecting message"}
        reflect_msg = Message[
          client: msg.client_id,
          local:  msg.local_tick,
          global: msg.global_tick]
        write_succeeds? reflect_msg, origin_conn
      end

      dest_streams.each do |stream|
        write_succeeds? msg, stream
      end
    end
    private :handle_message

    def write_succeeds? data, stream
      stream << data
      true
    rescue IOError, SystemCallError => ex
      log.debug {"closing #{stream}: #{ex}"}
      reject_stream stream
      false
    end
    private :write_succeeds?
  end
end
