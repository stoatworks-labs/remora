import Foundation

/// One rack as SuperRack lists it over ProLink: LAWO's `MR_RACK_INFO` (waveslib.tcl), 11 values,
/// `,isiiiiii(T|F)(T|F)i` on the wire: rackIndex, rackName, numOfInputs, numOfOutputs,
/// inputStemFormat, outputStemFormat, startingInputChannelIndex, startingOutputChannelIndex,
/// mute, in, sgProcessingGroup.
public struct ProLinkRack: Equatable {
    /// rackIndex: the rack's place in SuperRack's rack list, from 0.
    public var index: Int
    public var name: String
    public var inputs: Int
    public var outputs: Int
    public var inputStemFormat: Int
    public var outputStemFormat: Int
    /// startingInputChannelIndex: the first input channel feeding the rack, from 0, or -1 for none.
    /// ShowRack(channel) shows the rack this channel feeds.
    public var firstInputChannel: Int
    public var firstOutputChannel: Int
    public var muted: Bool
    /// `in` in MR_RACK_INFO, which the mc² never reads.
    public var isIn: Bool
    /// sgProcessingGroup: 0 main, 1–3 the groups, 255 none.
    public var processingGroup: Int

    public init(index: Int, name: String, inputs: Int = 1, outputs: Int = 1, inputStemFormat: Int = 100,
                outputStemFormat: Int = 100, firstInputChannel: Int = -1, firstOutputChannel: Int = -1,
                muted: Bool = false, isIn: Bool = true, processingGroup: Int = 0) {
        self.index = index
        self.name = name
        self.inputs = inputs
        self.outputs = outputs
        self.inputStemFormat = inputStemFormat
        self.outputStemFormat = outputStemFormat
        self.firstInputChannel = firstInputChannel
        self.firstOutputChannel = firstOutputChannel
        self.muted = muted
        self.isIn = isIn
        self.processingGroup = processingGroup
    }

    /// Whether this input channel (from 0) feeds the rack.
    public func takes(inputChannel ch: Int) -> Bool {
        firstInputChannel >= 0 && ch >= firstInputChannel && ch < firstInputChannel + max(1, inputs)
    }

    /// The record's 11 OSC arguments.
    public var arguments: [ProLinkOSC.Arg] {
        [.int(Int32(index)), .string(name), .int(Int32(inputs)), .int(Int32(outputs)),
         .int(Int32(inputStemFormat)), .int(Int32(outputStemFormat)), .int(Int32(firstInputChannel)),
         .int(Int32(firstOutputChannel)), .bool(muted), .bool(isIn), .int(Int32(processingGroup))]
    }

    /// One record from exactly its 11 arguments; nil if they are not ,isiiiiii(T|F)(T|F)i.
    public init?(record a: ArraySlice<ProLinkOSC.Arg>) {
        let a = Array(a)
        guard a.count == 11, case .int(let index) = a[0], case .string(let name) = a[1],
              case .bool(let muted) = a[8], case .bool(let isIn) = a[9], case .int(let group) = a[10]
        else { return nil }
        var ints: [Int] = []
        for v in a[2...7] {
            guard case .int(let i) = v else { return nil }
            ints.append(Int(i))
        }
        self.init(index: Int(index), name: name, inputs: ints[0], outputs: ints[1],
                  inputStemFormat: ints[2], outputStemFormat: ints[3], firstInputChannel: ints[4],
                  firstOutputChannel: ints[5], muted: muted, isIn: isIn, processingGroup: Int(group))
    }

    /// Every rack in a GiveRackInfo (`id count [rack] [rack] …`, as SuperRack sent it on
    /// 2026-11-07) or a NotifyRacksConfigChanged (`count [rack] …`, which the mc² reads as the whole
    /// list). Each record is an OSC array of its own, and loose ints are skipped. A record that
    /// does not read is left out, rather than failing the list.
    public static func list(from args: [ProLinkOSC.Arg]) -> [ProLinkRack] {
        var racks: [ProLinkRack] = []
        var i = 0
        while i < args.count {
            guard args[i] == .arrayStart else { i += 1; continue }
            guard let end = args[(i + 1)...].firstIndex(of: .arrayEnd) else { break }
            if let r = ProLinkRack(record: args[(i + 1)..<end]) { racks.append(r) }
            i = end + 1
        }
        return racks
    }
}
