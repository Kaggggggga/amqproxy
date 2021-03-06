module AMQProxy
  module AMQP
    abstract struct Frame
      getter type, channel
      def initialize(@type : Type, @channel : UInt16)
      end

      abstract def to_slice : Bytes

      def encode(io)
        io.write self.to_slice
      end

      def to_slice(body : Bytes)
        io = IO::Memory.new(8 + body.size)
        io.write_byte(@type.value)
        io.write_bytes(@channel, IO::ByteFormat::BigEndian)
        io.write_bytes(body.size.to_u32, IO::ByteFormat::BigEndian)
        io.write body
        io.write_byte(206_u8)
        io.to_slice
      end

      def self.decode(io)
        buf = uninitialized UInt8[7]
        io.read_fully(buf.to_slice)
        mem = IO::Memory.new(buf.to_slice)

        t = mem.read_byte
        raise IO::EOFError.new if t.nil?
        type = Type.new(t)
        channel = mem.read_bytes(UInt16, IO::ByteFormat::BigEndian)
        size = mem.read_bytes(UInt32, IO::ByteFormat::BigEndian)

        payload = Bytes.new(size + 1)
        io.read_fully(payload)

        frame_end = payload.at(size)
        if frame_end != 206
          raise InvalidFrameEnd.new("Frame-end was #{frame_end.to_s}, expected 206")
        end
        body = payload[0, size]
        case type
        when Type::Method then MethodFrame.decode(channel, body)
          #when Type::Header then HeaderFrame.decode(channel, body)
          #when Type::Body then BodyFrame.decode(channel, body)
          #when Type::Heartbeat then HeartbeatFrame.decode
        else GenericFrame.new(type, channel, body)
        end
      end
    end

    struct GenericFrame < Frame
      def initialize(@type : Type, @channel : UInt16,  @body : Bytes)
      end

      def to_slice
        super(@body)
      end
    end

    struct HeartbeatFrame < Frame
      def initialize
        @type = Type::Heartbeat
        @channel = 0_u16
      end

      def to_slice
        super(Slice(UInt8).new(0))
      end

      def self.decode
        self.new
      end
    end

    abstract struct MethodFrame < Frame
      def initialize(@channel : UInt16)
        @type = Type::Method
      end

      abstract def class_id : UInt16
      abstract def method_id : UInt16

      def to_slice(body : Bytes)
        io = IO::Memory.new(4 + body.size)
        io.write_bytes class_id, IO::ByteFormat::BigEndian
        io.write_bytes method_id, IO::ByteFormat::BigEndian
        io.write body
        super(io.to_slice)
      end

      def self.decode(channel, payload)
        body = AMQP::IO.new(payload)
        class_id = body.read_uint16
        case class_id
        when 10_u16 then Connection.decode(channel, body)
        when 20_u16 then Channel.decode(channel, body)
          #when 40_u16 then Exchange.decode(channel, body)
          #when 50_u16 then Queue.decode(channel, body)
         when 60_u16 then Basic.decode(channel, body)
          #when 90_u16 then Tx.decode(channel, body)
        else
          GenericFrame.new(Type::Method, channel, payload)
        end
      end
    end

    abstract struct Connection < MethodFrame
      def class_id
        10_u16
      end

      def initialize
        super(0_u16)
      end

      def self.decode(channel, body)
        method_id = body.read_uint16
        case method_id
        when 10_u16 then Start.decode(body)
        when 11_u16 then StartOk.decode(body)
        when 30_u16 then Tune.decode(body)
        when 31_u16 then TuneOk.decode(body)
        when 40_u16 then Open.decode(body)
        when 41_u16 then OpenOk.decode(body)
        when 50_u16 then Close.decode(body)
        when 51_u16 then CloseOk.decode(body)
        else raise "Unknown method_id #{method_id}"
        end
      end

      struct Start < Connection
        def method_id
          10_u16
        end

        def to_slice
          body = AMQP::IO.new(1 + 1 + 1 + @mechanisms.size + 1 + @locales.size)
          body.write_byte(@version_major)
          body.write_byte(@version_minor)
          body.write_table(@server_props)
          body.write_long_string(@mechanisms)
          body.write_long_string(@locales)
          super(body.to_slice)
        end

        def initialize(@version_major = 0_u8, @version_minor = 9_u8,
                       @server_props = { "Product" => "CloudAMQP" } of String => Field,
                       @mechanisms = "PLAIN", @locales = "en_US")
          super()
        end

        def self.decode(io)
          version_major = io.read_byte
          version_minor = io.read_byte
          server_props = io.read_table
          mech = io.read_long_string
          locales = io.read_long_string
          self.new(version_major, version_minor, server_props, mech, locales)
        end
      end

      struct StartOk < Connection
        getter client_props, mechanism, response, locale

        def method_id
          11_u16
        end

        def initialize(@client_props = {} of String => Field, @mechanism = "PLAIN",
                       @response = "\u0000guest\u0000guest", @locale = "en_US")
          super()
        end

        def to_slice
          body = AMQP::IO.new(1 + @mechanism.size + 4 + @response.size + 1 + @locale.size)
          body.write_table(@client_props)
          body.write_short_string(@mechanism)
          body.write_long_string(@response)
          body.write_short_string(@locale)
          super(body.to_slice)
        end

        def self.decode(io)
          props = io.read_table
          mechanism = io.read_short_string
          response = io.read_long_string
          locale = io.read_short_string
          self.new(props, mechanism, response, locale)
        end
      end

      struct Tune < Connection
        getter channel_max, frame_max, heartbeat
        def method_id
          30_u16
        end

        def initialize(@channel_max : UInt16, @frame_max : UInt32, @heartbeat : UInt16)
          super()
        end

        def to_slice
          body = AMQP::IO.new(2 + 4 + 2)
          body.write_int(@channel_max)
          body.write_int(@frame_max)
          body.write_int(@heartbeat)
          super(body.to_slice)
        end

        def self.decode(io)
          channel_max = io.read_uint16
          frame_max = io.read_uint32
          heartbeat = io.read_uint16
          self.new(channel_max, frame_max, heartbeat)
        end
      end

      struct TuneOk < Connection
        getter channel_max, frame_max, heartbeat
        def method_id
          31_u16
        end

        def initialize(@channel_max : UInt16, @frame_max : UInt32, @heartbeat : UInt16)
          super()
        end

        def to_slice
          body = AMQP::IO.new(2 + 4 + 2)
          body.write_int(@channel_max)
          body.write_int(@frame_max)
          body.write_int(@heartbeat)
          super(body.to_slice)
        end

        def self.decode(io)
          channel_max = io.read_uint16
          frame_max = io.read_uint32
          heartbeat = io.read_uint16
          self.new(channel_max, frame_max, heartbeat)
        end
      end

      struct Open < Connection
        getter vhost, reserved1, reserved2
        def method_id
          40_u16
        end

        def initialize(@vhost = "/", @reserved1 = "", @reserved2 = false)
          super()
        end

        def to_slice
          body = AMQP::IO.new(1 + @vhost.size + 1 + @reserved1.size + 1)
          body.write_short_string(@vhost)
          body.write_short_string(@reserved1)
          body.write_bool(@reserved2)
          super(body.to_slice)
        end

        def self.decode(io)
          vhost = io.read_short_string
          reserved1 = io.read_short_string
          reserved2 = io.read_bool
          self.new(vhost, reserved1, reserved2)
        end
      end

      struct OpenOk < Connection
        getter reserved1

        def method_id
          41_u16
        end

        def initialize(@reserved1 = "")
          super()
        end

        def to_slice
          body = AMQP::IO.new(1 + @reserved1.size)
          body.write_short_string(@reserved1)
          super(body.to_slice)
        end

        def self.decode(io)
          reserved1 = io.read_short_string
          self.new(reserved1)
        end
      end

      struct Close < Connection
        def method_id
          50_u16
        end

        getter reply_code, reply_text, failing_class_id, failing_method_id
        def initialize(@reply_code : UInt16, @reply_text : String, @failing_class_id : UInt16, @failing_method_id : UInt16)
          super()
        end

        def to_slice
          io = AMQP::IO.new(2 + 1 + @reply_text.size + 2 + 2)
          io.write_int(@reply_code)
          io.write_short_string(@reply_text)
          io.write_int(@failing_class_id)
          io.write_int(@failing_method_id)
          super(io.to_slice)
        end

        def self.decode(io)
          code = io.read_uint16
          text = io.read_short_string
          failing_class_id = io.read_uint16
          failing_method_id = io.read_uint16
          self.new(code, text, failing_class_id, failing_method_id)
        end
      end

      struct CloseOk < Connection
        def method_id
          51_u16
        end

        def to_slice
          super Bytes.new(0)
        end

        def self.decode(io)
          self.new
        end
      end
    end

    abstract struct Channel < MethodFrame
      def class_id
        20_u16
      end

      def self.decode(channel, body)
        method_id = body.read_uint16
        case method_id
        when 10_u16 then Open.decode(channel, body)
        when 11_u16 then OpenOk.decode(channel, body)
          #when 20_u16 then Flow.decode(channel, body)
          #when 21_u16 then FlowOk.decode(channel, body)
        when 40_u16 then Close.decode(channel, body)
        when 41_u16 then CloseOk.decode(channel, body)
        else raise "Unknown method_id #{method_id}"
        end
      end

      struct Open < Channel
        def method_id
          10_u16
        end

        getter reserved1

        def initialize(channel : UInt16, @reserved1 = "")
          super(channel)
        end

        def to_slice
          io = AMQP::IO.new(1 + @reserved1.size)
          io.write_short_string @reserved1
          super(io.to_slice)
        end

        def self.decode(channel, io)
          reserved1 = io.read_short_string
          self.new channel, reserved1
        end
      end

      struct OpenOk < Channel
        def method_id
          11_u16
        end

        getter reserved1

        def initialize(channel : UInt16, @reserved1 = "")
          super(channel)
        end

        def to_slice
          io = AMQP::IO.new(4 + @reserved1.size)
          io.write_long_string @reserved1
          super(io.to_slice)
        end

        def self.decode(channel, io)
          reserved1 = io.read_long_string
          self.new channel, reserved1
        end
      end

      struct Close < Channel
        def method_id
          40_u16
        end

        getter reply_code, reply_text, classid, methodid

        def initialize(channel : UInt16, @reply_code : UInt16, @reply_text : String, @classid : UInt16, @methodid : UInt16)
          super(channel)
        end

        def to_slice
          io = AMQP::IO.new(2 + 1 + @reply_text.size + 2 + 2)
          io.write_int(@reply_code)
          io.write_short_string(@reply_text)
          io.write_int(@classid)
          io.write_int(@methodid)
          super(io.to_slice)
        end

        def self.decode(channel, io)
          reply_code = io.read_uint16
          reply_text = io.read_short_string
          classid = io.read_uint16
          methodid = io.read_uint16
          self.new channel, reply_code, reply_text, classid, methodid
        end
      end

      struct CloseOk < Channel
        def method_id
          41_u16
        end

        def to_slice
          super(Slice(UInt8).new(0))
        end

        def self.decode(channel, io)
          self.new channel
        end
      end
    end

    abstract struct Basic < MethodFrame
      def class_id
        60_u16
      end

      def self.decode(channel, body)
        method_id = body.read_uint16
        case method_id
        when 10_u16 then Qos.decode(channel, body)
        when 11_u16 then QosOk.decode(channel, body)
        when 70_u16 then Get.decode(channel, body)
        else GenericBasic.new(method_id, channel,
                              body.to_slice[body.pos, body.size - body.pos])
        end
      end

      struct GenericBasic < Basic
        def method_id
          @method_id
        end

        def initialize(@method_id : UInt16, channel, @body : Bytes)
          super(channel)
        end

        def to_slice
          super(@body)
        end
      end

      struct Qos < Basic
        def method_id
          10_u16
        end

        getter prefetch_size, prefetch_count, global

        def initialize(channel : UInt16, @prefetch_size : UInt32,
                       @prefetch_count : UInt16, @global : Bool)
          super(channel)
        end

        def to_slice
          io = AMQP::IO.new(4 + 2 + 1)
          io.write_int @prefetch_size
          io.write_int @prefetch_count
          io.write_bool @global
          super(io.to_slice)
        end

        def self.decode(channel, io)
          prefetch_size = io.read_uint32
          prefetch_count = io.read_uint16
          global = io.read_bool
          self.new(channel, prefetch_size, prefetch_count, global)
        end
      end

      struct QosOk < Basic
        def method_id
          11_u16
        end

        def to_slice
          super(Slice(UInt8).new(0))
        end

        def self.decode(channel, io)
          self.new(channel)
        end
      end

      struct Get < Basic
        def method_id
          70_u16
        end

        getter reserved1, queue, no_ack

        def initialize(channel : UInt16, @reserved1 : UInt16,
                       @queue : String, @no_ack : Bool)
          super(channel)
        end

        def to_slice
          io = AMQP::IO.new(2 + 1 + @queue.size + 1)
          io.write_int @reserved1
          io.write_short_string @queue
          io.write_bool @no_ack
          super(io.to_slice)
        end

        def self.decode(channel, io)
          reserved1 = io.read_uint16
          queue = io.read_short_string
          no_ack = io.read_bool
          self.new(channel, reserved1, queue, no_ack)
        end
      end
    end
  end
end
