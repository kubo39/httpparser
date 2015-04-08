module httparse;

import std.conv : to;
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
  TokenError, StatusError, NewLine, HttpVersion,
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


class Request
{
  Headers headers;
  string method;
  string path;
  ubyte[] http_version;

  this(Headers _headers)
  {
    headers = _headers;
  }

  Result parse(ubyte[] buf)
  {
    ulong prev;

    ulong original_length = buf.length;
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
    http_version = buf[prev .. (prev+result.sep+1)];
    debug(httparse) writeln("HTTP_VERSION: ", cast(char[]) http_version);

    result = newline(buf);
    if (result.status != Status.Complete) {
      return result;
    }

    prev += result.sep + 1;
    ulong len = original_length - (prev + result.sep);

    return Result(Status.Complete, original_length);
  }
}


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
  debug(httparse) result.writeln;
}


class Response
{
  ubyte[] http_version;
  ushort code;
  string reason;
  Headers headers;

  this(Headers _headers)
  {
    headers = _headers;
  }

  Result parse(ubyte[] buf)
  {
    ulong prev;

    ulong original_length = buf.length;
    Result result = parse_version(buf[0 .. $]);
    if (result.status != Status.Complete) {
      return result;
    }
    http_version = buf[0 .. result.sep+1];
    debug(httparse) writeln("HTTP_VERSION: ", cast(char[]) http_version);
    prev = result.sep+2;

    result = parse_code(buf[prev .. prev+3]);
    if (result.status != Status.Complete) {
      return result;
    }
    debug(httparse) writeln("status code: ", code);
    prev += result.sep+1;

    result = parse_reason(buf[prev .. $]);
    if (result.status != Status.Complete) {
      return result;
    }
    reason = cast(string) cast(char[]) buf[prev .. prev+result.sep+1];
    debug(httparse) writeln("reason phrase: ", reason);

    return Result(Status.Complete, original_length);
  }

  Result parse_code(ubyte[] buf)
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
    code = cast(ushort) ((hundreds - '0'.to!ubyte) * 100 +
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
  debug(httparse) result.writeln;
}