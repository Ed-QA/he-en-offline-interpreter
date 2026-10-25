//
//  ORT.swift
//  HEENInterpreter
//
//  A very small Swift wrapper over the ONNX Runtime C API.
//
//  Why not the ObjC bindings (microsoft/onnxruntime-swift-package-manager)?
//  sherpa-onnx — our STT engine — already links onnxruntime-libs, and Xcode refuses
//  a build in which two artifacts both produce `onnxruntime.framework`
//  ("Multiple commands produce .../onnxruntime.framework"). So the whole app links
//  exactly ONE ONNX Runtime (the one sherpa-onnx pins) and this file provides the
//  small slice of the C API the OPUS-MT translator needs. The API surface below
//  intentionally mirrors the ObjC bindings' names (ORTEnv / ORTSession / ORTValue)
//  so ONNXTranslator.swift did not have to change beyond its import line.
//
//  Call signatures follow working in-the-wild Swift wrappers:
//  cristicretu/diri (Kokoro.swift) and moznoazachem/giga-pisar (swift/Ort.swift).
//

import Foundation
import onnxruntime

/// The ONNX Runtime API table (`OrtApi` from onnxruntime_c_api.h).
let heenOrt: UnsafePointer<OrtApi> = {
    guard let base = OrtGetApiBase(), let api = base.pointee.GetApi(UInt32(ORT_API_VERSION)) else {
        fatalError("ONNX Runtime: C API version \(ORT_API_VERSION) is not available")
    }
    return api
}()

/// CPU memory info, created once per process (ORT never copies tensor bytes).
let heenOrtMemInfo: OpaquePointer = {
    var info: OpaquePointer?
    let status = heenOrt.pointee.CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &info)
    if let status {
        let message = heenOrt.pointee.GetErrorMessage(status).map { String(cString: $0) } ?? "unknown"
        heenOrt.pointee.ReleaseStatus(status)
        fatalError("ONNX Runtime: CreateCpuMemoryInfo failed — \(message)")
    }
    guard let info else { fatalError("ONNX Runtime: CreateCpuMemoryInfo returned nothing") }
    return info
}()

enum ORTError: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        if case let .failed(message) = self { return message }
        return "ONNX Runtime error"
    }
}

@inline(__always)
func ortCheck(_ status: OpaquePointer?) throws {
    guard let status else { return }
    let message = heenOrt.pointee.GetErrorMessage(status).map { String(cString: $0) } ?? "ONNX Runtime error"
    heenOrt.pointee.ReleaseStatus(status)
    throw ORTError.failed(message)
}

/// Version string of the linked runtime, e.g. "1.28.2".
func ORTVersion() -> String {
    guard let base = OrtGetApiBase() else { return "unknown" }
    guard let getVersionString = base.pointee.GetVersionString else { return "unknown" }
    guard let cString = getVersionString() else { return "unknown" }
    return String(cString: cString)
}

/// Mirrors `ORTLoggingLevel` from the ObjC bindings.
enum ORTLoggingLevel {
    case verbose, info, warning, error, fatal

    var raw: OrtLoggingLevel {
        switch self {
        case .verbose: return ORT_LOGGING_LEVEL_VERBOSE
        case .info: return ORT_LOGGING_LEVEL_INFO
        case .warning: return ORT_LOGGING_LEVEL_WARNING
        case .error: return ORT_LOGGING_LEVEL_ERROR
        case .fatal: return ORT_LOGGING_LEVEL_FATAL
        }
    }
}

/// Mirrors `ORTTensorElementDataType` (only the two types OPUS-MT uses).
enum ORTElementType {
    case float, int64

    var raw: ONNXTensorElementDataType {
        switch self {
        case .float: return ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT
        case .int64: return ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64
        }
    }
}

/// Owns an `OrtEnv`. Mirrors `ORTEnv` from the ObjC bindings.
final class ORTEnv {
    let pointer: OpaquePointer

    init(loggingLevel: ORTLoggingLevel = .warning) throws {
        var env: OpaquePointer?
        try ortCheck(heenOrt.pointee.CreateEnv(loggingLevel.raw, "heen", &env))
        guard let env else { throw ORTError.failed("ONNX Runtime: CreateEnv failed") }
        pointer = env
    }

    deinit { heenOrt.pointee.ReleaseEnv(pointer) }
}

/// Owns an `OrtSessionOptions`. Mirrors `ORTSessionOptions` from the ObjC bindings.
final class ORTSessionOptions {
    let pointer: OpaquePointer

    init() throws {
        var options: OpaquePointer?
        try ortCheck(heenOrt.pointee.CreateSessionOptions(&options))
        guard let options else { throw ORTError.failed("ONNX Runtime: CreateSessionOptions failed") }
        pointer = options
    }

    func setIntraOpNumThreads(_ count: Int) throws {
        try ortCheck(heenOrt.pointee.SetIntraOpNumThreads(pointer, Int32(count)))
    }

    deinit { heenOrt.pointee.ReleaseSessionOptions(pointer) }
}

/// Tensor shape/element type, as returned by `ORTValue.tensorTypeAndShapeInfo()`.
struct ORTTensorTypeAndShapeInfo {
    let shape: [NSNumber]
}

/// A tensor (or any OrtValue). Mirrors `ORTValue` from the ObjC bindings.
final class ORTValue {
    /// The OrtValue itself.
    let ortPointer: OpaquePointer
    /// Bytes we allocated and handed to ORT; freed after the value is released.
    private let buffer: UnsafeMutableRawPointer?

    /// Wraps a tensor backed by our own copy of `tensorData`.
    init(tensorData: NSData, elementType: ORTElementType, shape: [NSNumber]) throws {
        let byteCount = tensorData.length
        let raw = UnsafeMutableRawPointer.allocate(byteCount: max(1, byteCount), alignment: 64)
        tensorData.getBytes(raw, length: byteCount)

        var dimensions = shape.map { $0.int64Value }
        var value: OpaquePointer?
        let status = heenOrt.pointee.CreateTensorWithDataAsOrtValue(
            heenOrtMemInfo,
            raw,
            byteCount,
            &dimensions,
            dimensions.count,
            elementType.raw,
            &value)

        if let status {
            raw.deallocate()
            let message = heenOrt.pointee.GetErrorMessage(status).map { String(cString: $0) } ?? "unknown"
            heenOrt.pointee.ReleaseStatus(status)
            throw ORTError.failed("ONNX Runtime: CreateTensorWithDataAsOrtValue failed — \(message)")
        }
        guard let value else {
            raw.deallocate()
            throw ORTError.failed("ONNX Runtime: CreateTensorWithDataAsOrtValue returned nothing")
        }

        ortPointer = value
        buffer = raw
    }

    /// Wraps a value ORT produced (e.g. a session output); we own and release it.
    init(owned value: OpaquePointer) {
        ortPointer = value
        buffer = nil
    }

    deinit {
        heenOrt.pointee.ReleaseValue(ortPointer)
        buffer?.deallocate()
    }


    func tensorTypeAndShapeInfo() throws -> ORTTensorTypeAndShapeInfo {
        var info: OpaquePointer?
        try ortCheck(heenOrt.pointee.GetTensorTypeAndShape(ortPointer, &info))
        guard let info else { throw ORTError.failed("ONNX Runtime: GetTensorTypeAndShape failed") }
        defer { heenOrt.pointee.ReleaseTensorTypeAndShapeInfo(info) }

        var dimensionCount = 0
        try ortCheck(heenOrt.pointee.GetDimensionsCount(info, &dimensionCount))
        var dimensions = [Int64](repeating: 0, count: dimensionCount)
        try ortCheck(heenOrt.pointee.GetDimensions(info, &dimensions, dimensionCount))
        return ORTTensorTypeAndShapeInfo(shape: dimensions.map { NSNumber(value: $0) })
    }

    /// Raw bytes of the tensor, copied out of ORT-owned memory.
    func tensorData() throws -> NSData {
        var info: OpaquePointer?
        try ortCheck(heenOrt.pointee.GetTensorTypeAndShape(ortPointer, &info))
        guard let info else { throw ORTError.failed("ONNX Runtime: GetTensorTypeAndShape failed") }
        defer { heenOrt.pointee.ReleaseTensorTypeAndShapeInfo(info) }

        var elementCount = 0
        try ortCheck(heenOrt.pointee.GetTensorShapeElementCount(info, &elementCount))
        var elementType = ONNX_TENSOR_ELEMENT_DATA_TYPE_UNDEFINED
        try ortCheck(heenOrt.pointee.GetTensorElementType(info, &elementType))

        var raw: UnsafeMutableRawPointer?
        try ortCheck(heenOrt.pointee.GetTensorMutableData(ortPointer, &raw))
        guard let raw else { return NSData() }

        let width = elementType == ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT
            ? MemoryLayout<Float>.size
            : MemoryLayout<Int64>.size
        return NSData(bytes: raw, length: elementCount * width)
    }
}

/// A loaded model. Mirrors `ORTSession` from the ObjC bindings.
final class ORTSession {
    private let session: OpaquePointer

    init(env: ORTEnv, modelPath: String, sessionOptions: ORTSessionOptions) throws {
        var session: OpaquePointer?
        try ortCheck(heenOrt.pointee.CreateSession(env.pointer, modelPath, sessionOptions.pointer, &session))
        guard let session else { throw ORTError.failed("ONNX Runtime: could not load \(modelPath)") }
        self.session = session
    }

    deinit { heenOrt.pointee.ReleaseSession(session) }

    /// Runs the graph once. Inputs are matched to the graph by name, not order.
    func run(withInputs inputs: [String: ORTValue],
             outputNames: [String],
             runOptions: Any? = nil) throws -> [String: ORTValue] {
        let inputNames = Array(inputs.keys)
        let duplicate = { (name: String) in name.withCString { strdup($0) } }
        let inputNamesC = inputNames.map(duplicate)
        let outputNamesC = outputNames.map(duplicate)
        defer { (inputNamesC + outputNamesC).forEach { free($0) } }

        var inputNamePointers = inputNamesC.map { $0.map { UnsafePointer($0) } }
        var outputNamePointers = outputNamesC.map { $0.map { UnsafePointer($0) } }
        var values: [OpaquePointer?] = inputNames.map { inputs[$0]?.ortPointer }
        var outputs = [OpaquePointer?](repeating: nil, count: outputNames.count)

        try ortCheck(heenOrt.pointee.Run(
            session,
            nil,
            &inputNamePointers,
            &values,
            values.count,
            &outputNamePointers,
            outputNames.count,
            &outputs))

        var result: [String: ORTValue] = [:]
        for (index, name) in outputNames.enumerated() {
            if let value = outputs[index] {
                result[name] = ORTValue(owned: value)
            }
        }
        return result
    }
}

