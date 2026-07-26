// Placeholder so the target has at least one Swift source file.
//
// The real contents of this target are the types generated from ohagey.proto
// by Scripts/generate-proto.sh (decision 0007). Until that has been run, SPM
// warns that the target has no sources. This file can be deleted once
// ohagey.pb.swift is committed.

/// Version of the IPC schema in ohagey.proto. Bump when the wire format changes
/// incompatibly so client and server can refuse to talk past each other.
public enum OhageyProtoSchema {
    public static let version = 1
}
