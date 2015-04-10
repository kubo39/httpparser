module httparse;

import std.conv : to, octal;
import std.ascii : isDigit;


debug(httparse) import std.stdio : writeln;


/// Determines if byte is a token char.
///
/// > token          = 1*tchar
/// >
/// > tchar          = "!" / "#" / "$" / "%" / "&" / "'" / "*"
/// >                / "+" / "-" / "." / "^" / "_" / "`" / "|" / "~"
/// >                / DIGIT / ALPHA
/// >                ; any VCHAR, except delimiters
///
//
//
// From [RFC 7230](https://tools.ietf.org/html/rfc7230):
//
// > reason-phrase  = *( HTAB / SP / VCHAR / obs-text )
// > HTAB           = %x09        ; horizontal tab
// > VCHAR          = %x21-7E     ; visible (printing) characters
// > obs-text       = %x80-FF
//
// > A.2.  Changes from RFC 2616
// >
// > Non-US-ASCII content in header fields and the reason phrase
// > has been obsoleted and made opaque (the TEXT rule was removed).
//
// Note that the following implementation deliberately rejects the obsoleted (non-US-ASCII) text range.
//


bool is_token(ubyte b)
{
  return (b > 0x1F && b < 0x7F);
}


enum Status {
  Complete,
  Partial,
  Error,
}


enum Error : ulong {
  TokenError, StatusError, NewLine, HttpVersion,  TooManyHeaders, HeaderName, HeaderValue,
}


struct Result
{
  Status status;
  ulong sep;
}


struct Header
{
  string name;
  ubyte[] value;

  this(string _name, ubyte[] _value)
  {
    name = _name;
    value = _value;
  }
}


class Headers
{
  Header*[] headers;
  size_t pos;

  this(Header*[] _headers, size_t _pos = 0)
  {
    headers = _headers;
    pos = _pos;
  }

  bool empty() @property
  {
    return pos >= headers.length;
  }

  Header* front() @property
  {
    return headers[pos];
  }

  void popFront() @property
  {
    ++pos;
  }

  Header* opIndex(int n)
  {
    return headers[n];
  }

  size_t length() @property
  {
    return headers.length;
  }

  void pushBack(Header* header)
  {
    headers ~= header;
  }

  template opOpAssign(string op) if (op == "~")
  {
    alias pushBack opOpAssign;
  }
}


// Headers implements InputRange interface.
unittest
{
  import std.range;
  assert(isInputRange!Headers);
}


unittest
{
  Header*[] arr = [];

  auto headers = new Headers(arr);
  headers ~= new Header(null, null);
  assert(headers.length == 1);
}


Result parse_token(ubyte[] buf)
{
  foreach (i, b; buf) {
    if (b == ' '.to!ubyte || b == '\r'.to!ubyte || b == '\n'.to!ubyte) {
      return Result(Status.Complete, i);
    }
    else if (!is_token(b)) {
      return Result(Status.Error, Error.TokenError);
    }
  }
  assert(false);
}


Result newline(ubyte[] buf)
{
  Result result = Result(Status.Error, Error.NewLine);

  if (buf.length == 0) {
    return Result(Status.Partial, ulong.max);
  }

  foreach (i, b; buf) {
    if (b == '\r'.to!ubyte) {
      if (buf[i+1] == '\n'.to!ubyte) {
        result = Result(Status.Partial, ulong.max);
      }
    }
    else if (b == '\n'.to!ubyte) {
      return Result(Status.Complete, i);
    }
  }
  return result;
}


Result parse_version(ubyte[] buf)
{
  uint i = 0;

  if (buf[i] != 'H'.to!ubyte) return Result(Status.Error, Error.HttpVersion);
  if (buf[++i] != 'T'.to!ubyte) return Result(Status.Error, Error.HttpVersion);
  if (buf[++i] != 'T'.to!ubyte) return Result(Status.Error, Error.HttpVersion);
  if (buf[++i] != 'P'.to!ubyte) return Result(Status.Error, Error.HttpVersion);
  if (buf[++i] != '/'.to!ubyte) return Result(Status.Error, Error.HttpVersion);
  if (buf[++i] != '1'.to!ubyte) return Result(Status.Error, Error.HttpVersion);
  if (buf[++i] != '.'.to!ubyte) return Result(Status.Error, Error.HttpVersion);

  if (buf[++i] == '1'.to!ubyte) {
    return Result(Status.Complete, i);
  }
  else if (buf[i] == '0'.to!ubyte) {
    return Result(Status.Complete, i);
  }
  return Result(Status.Error, Error.HttpVersion);
}


Result parse_header(Headers headers, ubyte[] buf)
{
  int i = 0;
  int last_i = 0;

headers: foreach (header; headers) {
    if (buf.length == i) {
      return Result(Status.Partial, ulong.max);
    }
    ++i;
    ubyte b = buf[i];

    if (b == '\r'.to!ubyte) {
      if (buf[++i] != '\n'.to!ubyte) {
        return Result(Status.Error, Error.NewLine);
      }
      return Result(Status.Complete, i);
    }
    else if (b == '\n'.to!ubyte) {
      ++i;
      return Result(Status.Complete, i);
    }

    last_i = i;

    // parse header until Colon.
    for (;;) {
      if (buf.length == i) {
        return Result(Status.Partial, ulong.max);
      }

      b = buf[i];
      ++i;
      if (b == ':'.to!ubyte) {
        header.name = cast(string) cast(char[]) buf[last_i .. i-1];
        debug(httparse) writeln(cast(char[]) header.name);
        break;
      }
      else if (!is_token(b)) {
        return Result(Status.Error, Error.HeaderName);
      }
    }

    // wat whitespace between colon and value.
    for (;;) {
      if (buf.length == i) {
        return Result(Status.Partial, ulong.max);
      }

      b = buf[i];
      ++i;
      if (!(b == ' '.to!ubyte || b == '\t'.to!ubyte)) {
        --i;
        last_i = i;
        break;
      }
    }

    // parse value til EOL
    while (buf.length - i >= 8) {
      foreach (_; 0 .. 8) {
        b = buf[i];
        ++i;
        if (!is_token(b)) {
          if ((b < octal!40 && b != octal!11) || b == octal!177) {
            if (b == '\r'.to!ubyte) {
              if(buf[i] != '\n'.to!ubyte) {
                return Result(Status.Error, Error.HeaderValue);
              }
              header.value = buf[last_i .. i-1];
              debug(httparse) writeln(cast(char[]) header.value);
              continue headers;
            }
            else if (b == '\n'.to!ubyte) {
              header.value = buf[last_i .. i];
              debug(httparse) writeln(cast(char[]) header.value);
              continue headers;
            }
            else {
              return Result(Status.Error, Error.HeaderValue);
            }
          }
        }
      }
    }

    for (;;) {
      if (buf.length == i) {
        return Result(Status.Partial, ulong.max);
      }

      b = buf[i];
      ++i;
      if (!(is_token(b))) {
        if ((b < octal!40 && b != octal!11) || b == octal!177) {
          if (b == '\r'.to!ubyte) {
            if(buf[i] != '\n'.to!ubyte) {
              return Result(Status.Error, Error.HeaderValue);
            }
            header.value = buf[last_i .. i-1];
            debug(httparse) writeln(cast(char[]) header.value);
            break;
          }
          else if (b == '\n'.to!ubyte) {
            header.value = buf[last_i .. i];
            debug(httparse) writeln(cast(char[]) header.value);
            break;
          }
          else {
            return Result(Status.Error, Error.HeaderValue);
          }
        }
      }
    }
  }
  return Result(Status.Error, Error.TooManyHeaders);
}


class Request
{
  Headers headers;
  string method;
  string path;
  string http_version;

  this(Headers _headers)
  {
    headers = _headers;
  }

  Result parse(ubyte[] buf)
  {
    ulong prev;

    Result result = parse_token(buf);
    if (result.status != Status.Complete) {
      return result;
    }
    method = cast(string) cast(char[])buf[0 .. result.sep];
    debug(httparse) writeln("method: ", method);
    prev = result.sep+1;

    result = parse_token(buf[prev .. $]);
    if (result.status != Status.Complete) {
      return result;
    }

    path = cast(string) cast(char[]) buf[prev .. (prev+result.sep)];
    debug(httparse) writeln("path: ", path);
    prev += result.sep+1;

    result = parse_version(buf[prev .. $]);
    if (result.status != Status.Complete) {
      return result;
    }
    http_version = cast(string) cast(char[]) buf[prev .. (prev+result.sep+1)];
    debug(httparse) writeln("HTTP_VERSION: ", http_version);

    result = newline(buf);
    if (result.status != Status.Complete) {
      return result;
    }

    prev = result.sep;

    result = parse_header(headers, buf[prev .. $]);
    if (result.status != Status.Complete) {
      return result;
    }
    return Result(Status.Complete, buf.length);
  }
}


// simple request
unittest
{
  Header*[] arr = [new Header(null, null),
                   new Header(null, null),
                   new Header(null, null),
                   new Header(null, null)];

  auto headers = new Headers(arr);
  auto req = new Request(headers);

  string buffer = "GET / HTTP/1.1\r\n\r\n";
  auto result = req.parse(cast(ubyte[]) buffer);
  assert(req.method == "GET");
  assert(req.path == "/");
  assert(req.http_version == "HTTP/1.1");
  debug(httparse) result.writeln;
}


// request headers
unittest
{
  Header*[] arr = [new Header(null, null),
                   new Header(null, null),
                   new Header(null, null),
                   new Header(null, null)];

  auto headers = new Headers(arr);
  auto req = new Request(headers);

  string buffer = "GET / HTTP/1.1\r\nHost: foo.com\r\nCookie: \r\n\r\n";
  auto result = req.parse(cast(ubyte[]) buffer);
  assert(req.method == "GET");
  assert(req.path == "/");
  assert(req.http_version == "HTTP/1.1");
  assert(headers[0].name == "Host");
  assert(headers[0].value == cast(ubyte[])"foo.com");
  assert(headers[1].name == "Cookie");
  assert(headers[1].value == cast(ubyte[])"");
  debug(httparse) result.writeln;
}


class Response
{
  string http_version;
  ushort status_code;
  string reason;
  Headers headers;

  this(Headers _headers)
  {
    headers = _headers;
  }

  Result parse(ubyte[] buf)
  {
    ulong prev;

    Result result = parse_version(buf[0 .. $]);
    if (result.status != Status.Complete) {
      return result;
    }
    http_version = cast(string) cast(char[]) buf[0 .. result.sep+1];
    debug(httparse) writeln("HTTP_VERSION: ", http_version);
    prev = result.sep+2;

    result = parse_status_code(buf[prev .. prev+3]);
    if (result.status != Status.Complete) {
      return result;
    }
    debug(httparse) writeln("status code: ", status_code);
    prev += result.sep+1;

    result = parse_reason(buf[prev .. $]);
    if (result.status != Status.Complete) {
      return result;
    }
    reason = cast(string) cast(char[]) buf[prev+1 .. prev+result.sep];
    debug(httparse) writeln("reason phrase: ", reason);

    return Result(Status.Complete, buf.length);
  }

  Result parse_status_code(ubyte[] buf)
  {
    int i;

    if (!buf[i].isDigit) {
      return Result(Status.Error, Error.StatusError);
    }
    ubyte hundreds = buf[i];

    if (!buf[++i].isDigit) {
      return Result(Status.Error, Error.StatusError);
    }
    ubyte tens = buf[i];

    if (!buf[++i].isDigit) {
      return Result(Status.Error, Error.StatusError);
    }
    ubyte ones = buf[i];
    status_code = cast(ushort) ((hundreds - '0'.to!ubyte) * 100 +
                                (tens - '0'.to!ubyte) * 10 +
                                (ones -  '0'.to!ubyte));

    return Result(Status.Complete, i);
  }

  Result parse_reason(ubyte[] buf)
  {
    foreach (i, b; buf) {
      if (b == '\r'.to!ubyte || b == '\n'.to!ubyte) {
        return Result(Status.Complete, i);
      }
      else if (!((b >= 0x20 && b <= 0x7E) || b == '\t'.to!ubyte)) {
        return Result(Status.Error, Error.StatusError);
      }
    }
    assert(false);
  }
}


unittest
{
  Header*[] arr = [new Header(null, null),
                   new Header(null, null),
                   new Header(null, null),
                   new Header(null, null)];

  auto headers = new Headers(arr);

  auto res = new Response(headers);

  string buffer = "HTTP/1.1 200 OK\r\n\r\n";
  auto result = res.parse(cast(ubyte[]) buffer);
  assert(res.http_version == "HTTP/1.1");
  assert(res.status_code == 200);
  assert(res.reason == "OK");
  debug(httparse) result.writeln;
}


// reason with space & tab.
unittest
{
  Header*[] arr = [new Header(null, null),
                   new Header(null, null),
                   new Header(null, null),
                   new Header(null, null)];

  auto headers = new Headers(arr);

  auto res = new Response(headers);

  string buffer = "HTTP/1.1 101 Switching Protocols\t\r\n\r\n";
  auto result = res.parse(cast(ubyte[]) buffer);
  assert(res.http_version == "HTTP/1.1");
  assert(res.status_code == 101);
  assert(res.reason == "Switching Protocols\t");
  debug(httparse) result.writeln;
}