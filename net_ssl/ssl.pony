use "net"

use @SSL_ctrl[ILong](
  ssl: Pointer[_SSL],
  op: I32,
  arg: ILong,
  parg: Pointer[None])
use @SSL_new[Pointer[_SSL]](ctx: Pointer[_SSLContext] tag)
use @SSL_free[None](ssl: Pointer[_SSL] tag)
use @SSL_set_verify[None](ssl: Pointer[_SSL], mode: I32, cb: Pointer[U8])
use @BIO_s_mem[Pointer[U8]]()
use @BIO_new[Pointer[_BIO]](typ: Pointer[U8])
use @SSL_set_bio[None](ssl: Pointer[_SSL], rbio: Pointer[_BIO] tag, wbio: Pointer[_BIO] tag)
use @SSL_set_accept_state[None](ssl: Pointer[_SSL])
use @SSL_set_connect_state[None](ssl: Pointer[_SSL])
use @SSL_do_handshake[I32](ssl: Pointer[_SSL])
use @SSL_get0_alpn_selected[None](ssl: Pointer[_SSL] tag, data: Pointer[Pointer[U8] iso],
  len: Pointer[U32]) if "openssl_1.1.x" or "openssl_3.0.x"
use @SSL_pending[I32](ssl: Pointer[_SSL])
use @SSL_read[I32](ssl: Pointer[_SSL], buf: Pointer[U8] tag, len: U32)
use @SSL_write[I32](ssl: Pointer[_SSL], buf: Pointer[U8] tag, len: U32)
use @BIO_read[I32](bio: Pointer[_BIO] tag, buf: Pointer[U8] tag, len: U32)
use @BIO_write[I32](bio: Pointer[_BIO] tag, buf: Pointer[U8] tag, len: U32)
use @SSL_get_error[I32](ssl: Pointer[_SSL], ret: I32)
use @BIO_ctrl_pending[USize](bio: Pointer[_BIO] tag)
use @SSL_has_pending[I32](ssl: Pointer[_SSL]) if "openssl_1.1.x" or "openssl_3.0.x"
use @SSL_get_peer_certificate[Pointer[X509]](ssl: Pointer[_SSL]) if "openssl_1.1.x" or "openssl_0.9.0"
use @SSL_get1_peer_certificate[Pointer[X509]](ssl: Pointer[_SSL]) if "openssl_3.0.x"

primitive _SSL
primitive _BIO

primitive SSLHandshake
primitive SSLAuthFail
primitive SSLReady
primitive SSLError

type SSLState is (SSLHandshake | SSLAuthFail | SSLReady | SSLError)

class SSL
  """
  An SSL session manages handshakes, encryption and decryption. It is not tied
  to any transport layer.
  """
  let _hostname: String
  var _ssl: Pointer[_SSL]
  var _input: Pointer[_BIO] tag
  var _output: Pointer[_BIO] tag
  var _state: SSLState = SSLHandshake
  var _read_buf: Array[U8] iso = []

  new _create(
    ctx: Pointer[_SSLContext] tag,
    server: Bool,
    verify: Bool,
    hostname: String = "")
    ?
  =>
    """
    Create a client or server SSL session from a context.
    """
    if ctx.is_null() then error end
    _hostname = hostname

    _ssl = @SSL_new(ctx)
    if _ssl.is_null() then error end

    let mode = if verify then I32(3) else I32(0) end
    @SSL_set_verify(_ssl, mode, Pointer[U8])

    _input = @BIO_new(@BIO_s_mem())
    if _input.is_null() then error end

    _output = @BIO_new(@BIO_s_mem())
    if _output.is_null() then error end

    @SSL_set_bio(_ssl, _input, _output)

    if
      (_hostname.size() > 0)
        and not DNS.is_ip4(_hostname)
        and not DNS.is_ip6(_hostname)
    then
      // SSL_set_tlsext_host_name
      @SSL_ctrl(_ssl, 55, 0, _hostname.cstring())
    end

    if server then
      @SSL_set_accept_state(_ssl)
    else
      @SSL_set_connect_state(_ssl)
      @SSL_do_handshake(_ssl)
    end

  fun box alpn_selected(): (ALPNProtocolName | None) =>
    """
    Get the protocol identifier negotiated via ALPN
    """
    var ptr: Pointer[U8] iso = recover Pointer[U8] end
    var len = U32(0)
    ifdef "openssl_1.1.x" or "openssl_3.0.x" then
      @SSL_get0_alpn_selected(_ssl, addressof ptr, addressof len)
    end

    if ptr.is_null() then None
    else
      recover val String.copy_cpointer(consume ptr, USize.from[U32](len)) end
    end

  fun state(): SSLState =>
    """
    Returns the SSL session state.
    """
    _state

  fun ref read(expect: USize = 0): (Array[U8] iso^ | None) =>
    """
    Returns unencrypted bytes to be passed to the application. If `expect` is
    non-zero, the number of bytes returned will be exactly `expect`. If no data
    (or less than `expect` bytes) is available, this returns None.
    """
    let offset = _read_buf.size()

    var len = if expect > 0 then
      if offset >= expect then
        return _read_buf = []
      end

      expect - offset
    else
      1024
    end

    let max = if expect > 0 then expect - offset else USize.max_value() end
    let pending = @SSL_pending(_ssl).usize()

    if pending > 0 then
      if expect > 0 then
        len = len.min(pending)
      else
        len = pending
      end

      _read_buf.undefined(offset + len)
      @SSL_read(_ssl, _read_buf.cpointer(offset), len.u32())
    else
      _read_buf.undefined(offset + len)
      let r =
        @SSL_read(_ssl, _read_buf.cpointer(offset), len.u32())

      if r <= 0 then
        match @SSL_get_error(_ssl, r)
        | 1 | 5 | 6 => _state = SSLError
        | 2 =>
          // SSL buffer has more data but it is not yet decoded (or something)
          _read_buf.truncate(offset)
          return None
        end

        _read_buf.truncate(offset)
      else
        _read_buf.truncate(offset + r.usize())
      end
    end

    let ready = if expect == 0 then
      _read_buf.size() > 0
    else
      _read_buf.size() == expect
    end

    if ready then
      _read_buf = []
    else
      // try and read again any pending data that SSL hasn't decoded yet
      if @BIO_ctrl_pending(_input) > 0 then
        read(expect)
      else
        ifdef "openssl_1.1.x" or "openssl_3.0.x" then
          // try and read again any data already decoded from SSL that hasn't
          // been read via `SSL_has_pending` that was added in 1.1
          // This mailing list post has a good description of what it is for:
          // https://mta.openssl.org/pipermail/openssl-users/2017-January/005110.html
          if @SSL_has_pending(_ssl) == 1 then
            read(expect)
          end
        end
      end
    end

  fun ref write(data: ByteSeq) ? =>
    """
    When application data is sent, add it to the SSL session. Raises an error
    if the handshake is not complete.
    """
    if _state isnt SSLReady then error end

    if data.size() > 0 then
      @SSL_write(_ssl, data.cpointer(), data.size().u32())
    end

  fun ref receive(data: ByteSeq) =>
    """
    When data is received, add it to the SSL session.
    """
    @BIO_write(_input, data.cpointer(), data.size().u32())

    if _state is SSLHandshake then
      let r = @SSL_do_handshake(_ssl)

      if r > 0 then
        _verify_hostname()
      else
        match @SSL_get_error(_ssl, r)
        | 1 => _state = SSLAuthFail
        | 5 | 6 => _state = SSLError
        end
      end
    end

  fun ref can_send(): Bool =>
    """
    Returns true if there are encrypted bytes to be passed to the destination.
    """
    @BIO_ctrl_pending(_output) > 0

  fun ref send(): Array[U8] iso^ ? =>
    """
    Returns encrypted bytes to be passed to the destination. Raises an error
    if no data is available.
    """
    let len = @BIO_ctrl_pending(_output)
    if len == 0 then error end

    let buf = recover Array[U8] .> undefined(len) end
    @BIO_read(_output, buf.cpointer(), buf.size().u32())
    buf

  fun ref dispose() =>
    """
    Dispose of the session.
    """
    if not _ssl.is_null() then
      @SSL_free(_ssl)
      _ssl = Pointer[_SSL]
    end

  fun _final() =>
    """
    Dispose of the session.
    """
    if not _ssl.is_null() then
      @SSL_free(_ssl)
    end

  fun ref _verify_hostname() =>
    """
    Verify that the certificate is valid for the given hostname.
    """
    if _hostname.size() > 0 then
      let cert = ifdef "openssl_3.0.x" then
        @SSL_get1_peer_certificate(_ssl)
      elseif "openssl_1.1.x" or "openssl_0.9.0" then
        @SSL_get_peer_certificate(_ssl)
      else
        compile_error "You must select an SSL version to use."
      end
      let ok = X509.valid_for_host(cert, _hostname)

      if not cert.is_null() then
        @X509_free(cert)
      end

      if not ok then
        _state = SSLAuthFail
        return
      end
    end

    _state = SSLReady
