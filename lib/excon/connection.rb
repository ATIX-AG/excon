module Excon
  class Connection

    unless defined?(:CHUNK_SIZE)
      CHUNK_SIZE = 1048576 # 1 megabyte
    end

    def initialize(url)
      @uri = URI.parse(url)
    end

    def request(params)
      params[:path] ||= ''
      unless params[:path][0..0] == '/'
        params[:path] = '/' + params[:path].to_s
      end
      if params[:query] && !params[:query].empty?
        params[:path] << "?#{params[:query]}"
      end
      request = "#{params[:method]} #{params[:path]} HTTP/1.1\r\n"
      params[:headers] ||= {}
      params[:headers]['Host'] = params[:host] || @uri.host
      if params[:body] && !params[:headers]['Content-Length']
        params[:headers]['Content-Length'] = params[:body].length
      end
      for key, value in params[:headers]
        request << "#{key}: #{value}\r\n"
      end
      request << "\r\n"
      connection.write(request)

      if params[:body]
        if params[:body].is_a?(String)
          connection.write(params[:body])
        else
          while chunk = params[:body].read(CHUNK_SIZE)
            connection.write(chunk)
          end
        end
      end

      response = Excon::Response.new
      response.status = connection.readline[9..11].to_i
      if params[:expects] && ![*params[:expects]].include?(response.status)
        error = true
      end
      while true
        data = connection.readline.chomp!
        if data == ""
          break
        end
        header = data.split(': ')
        response.headers[header[0]] = header[1]
      end

      unless params[:method] == 'HEAD' || [204, 304, *(100..199)].include?(response.status)
        if (error && params[:error_parser]) || params[:parser]
          if error
            parser = params[:error_parser]
          elsif params[:parser]
            parser = params[:parser]
          end
          body = Nokogiri::XML::SAX::PushParser.new(parser)
        elsif params[:block]
          body = nil
        else
          body = ''
        end

        if response.headers['Content-Length']
          if error || !params[:block]
            body << connection.read(response.headers['Content-Length'].to_i)
          else
            remaining = response.headers['Content-Length'].to_i
            while remaining > 0
              params[:block].call(connection.read([CHUNK_SIZE, remaining].min))
              remaining -= CHUNK_SIZE;
            end
          end
        elsif response.headers['Transfer-Encoding'] == 'chunked'
          while true
            chunk_size = connection.readline.chomp!.to_i(16)
            # 2 == "/r/n".length
            chunk = connection.read(chunk_size + 2)[0...-2]
            if chunk_size == 0
              break
            else
              if error || !params[:block]
                body << chunk
              else
                params[:block].call(chunk)
              end
            end
          end
        elsif response.headers['Connection'] == 'close'
          body << connection.read
          @connection = nil
        end

        if parser
          body.finish
          response.body = parser.response
        else
          response.body = body
        end
      end

      if error
        raise(Excon::Errors.status_error(params[:expects], response.status, response))
      else
        response
      end
    end

    private

    def connection
      if !@connection || @connection.closed?
        @connection = TCPSocket.open(@uri.host, @uri.port)
        if @uri.scheme == 'https'
          @ssl_context = OpenSSL::SSL::SSLContext.new
          @ssl_context.verify_mode = OpenSSL::SSL::VERIFY_NONE
          @connection = OpenSSL::SSL::SSLSocket.new(@connection, @ssl_context)
          @connection.sync_close = true
          @connection.connect
        end
      end
      @connection
    end

  end
end
