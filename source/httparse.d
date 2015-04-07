module httparse;

import std.conv : to;


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

    ulong len = original_length - (prev + result.sep);

    return Result(Status.Complete, original_length);
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
  ++i;
  if (buf[i] != 'T'.to!ubyte) return Result(Status.Error, Error.HttpVersion);
  ++i;
  if (buf[i] != 'T'.to!ubyte) return Result(Status.Error, Error.HttpVersion);
  ++i;
  if (buf[i] != 'P'.to!ubyte) return Result(Status.Error, Error.HttpVersion);
  ++i;
  if (buf[i] != '/'.to!ubyte) return Result(Status.Error, Error.HttpVersion);
  ++i;
  if (buf[i] != '1'.to!ubyte) return Result(Status.Error, Error.HttpVersion);
  ++i;
  if (buf[i] != '.'.to!ubyte) return Result(Status.Error, Error.HttpVersion);
  ++i;

  if (buf[i] == '1'.to!ubyte) {
    return Result(Status.Complete, i);
  }
  else if (buf[i] == '0'.to!ubyte) {
    return Result(Status.Complete, i);
  }
  return Result(Status.Error, Error.HttpVersion);
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
