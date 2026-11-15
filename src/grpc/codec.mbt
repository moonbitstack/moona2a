// The messages of the gRPC binding: `a2a.proto` and the two `google.rpc` messages a refusal
// travels in, read once, and each message moved between the binary form on the wire and the
// JSON form the server and the client work in.

///|
/// `google.rpc.Status` and `google.rpc.ErrorInfo` as googleapis declares them.
let rpc_proto : String =
  #|syntax = "proto3";
  #|package google.rpc;
  #|import "google/protobuf/any.proto";
  #|message Status {
  #|  int32 code = 1;
  #|  string message = 2;
  #|  repeated google.protobuf.Any details = 3;
  #|}
  #|message ErrorInfo {
  #|  string reason = 1;
  #|  string domain = 2;
  #|  map<string, string> metadata = 3;
  #|}

///|
/// The file `a2a.proto` builds.
let a2a : @reflect.FileDescriptor = build("a2a.proto", a2a_proto)

///|
/// The file of the two `google.rpc` messages.
let rpc : @reflect.FileDescriptor = build("google/rpc/status.proto", rpc_proto)

///|
/// Every message of the two files, by full name.
let messages : Map[String, @reflect.MessageDescriptor] = {
  let index = Map([])
  fn add(list : Array[@reflect.MessageDescriptor]) -> Unit {
    for message in list {
      index[message.full_name] = message
      add(message.nested_messages)
    }
  }
  add(a2a.messages)
  add(rpc.messages)
  index
}

///|
/// Build a file from its text and register its types where moonproto's JSON codec resolves an
/// enum, an `Any` and a nested message. The texts are fixed, so a failure here is a bug.
fn build(path : String, text : String) -> @reflect.FileDescriptor {
  let file = @desc.build_file(@parser.parse(path, text)) catch {
    error => abort("\{path} does not build: \{error}")
  }
  @known.register_all()
  if @reflect.global_files.find_file_by_path(file.path) is None {
    @reflect.global_files.register(file) catch {
      _ => ()
    }
    fn add(list : Array[@reflect.MessageDescriptor]) -> Unit {
      for message in list {
        @reflect.global_types.register_message(
          @dynamic.new_message_type(message),
        ) catch {
          _ => ()
        }
        for item in message.nested_enums {
          @reflect.global_types.register_enum(@dynamic.new_enum_type(item)) catch {
            _ => ()
          }
        }
        add(message.nested_messages)
      }
    }
    add(file.messages)
    for item in file.enums {
      @reflect.global_types.register_enum(@dynamic.new_enum_type(item)) catch {
        _ => ()
      }
    }
  }
  file
}

///|
/// A fresh message of type `name`.
fn message(name : String) -> @dynamic.Message raise {
  match messages.get(name) {
    Some(descriptor) => @dynamic.Message::new(descriptor)
    None =>
      match @known.message_descriptor(name) {
        Some(descriptor) => @dynamic.Message::new(descriptor)
        None => fail("no message is named \{name}")
      }
  }
}

///|
/// The JSON form of the message of type `name` written in `bytes`.
pub fn decode(name : String, bytes : BytesView) -> Json raise {
  let read = message(name)
  @proto.decode(bytes, read)
  @protojson.to_json(read)
}

///|
/// The binary form of the message of type `name` whose JSON form is `json`.
pub fn encode(name : String, json : Json) -> Bytes raise {
  let written = message(name)
  @protojson.from_json(written, json)
  @proto.encode(written)
}

///|
/// The request type and the reply type of `rpc`, as `A2AService` declares them. A streaming
/// method's reply type is that of each message of the stream.
pub fn types_of(rpc : @moona2a.Method) -> (String, String) {
  for service in a2a.services {
    for declared in service.methods {
      if declared.name == rpc.name() {
        return (full_name(declared.input_type), full_name(declared.output_type))
      }
    }
  }
  abort("A2AService declares no \{rpc.name()}")
}

///|
/// The full name of a type the service names: a qualified name without its leading dot, a bare
/// one in the package of `a2a.proto`.
fn full_name(name : String) -> String {
  match name.strip_prefix(".") {
    Some(rest) => rest.to_owned()
    None =>
      if name.contains(".") {
        name
      } else {
        "\{a2a.package_name}.\{name}"
      }
  }
}

///|
/// The details of a `google.rpc.Status`, as `grpc-status-details-bin` carries it: each detail in
/// its JSON form, an `ErrorInfo` with its `@type`.
pub fn details_of(status : BytesView) -> Array[Json] raise {
  match decode("google.rpc.Status", status) {
    Object(fields) =>
      match fields.get("details") {
        Some(Array(details)) => details
        _ => []
      }
    _ => []
  }
}
