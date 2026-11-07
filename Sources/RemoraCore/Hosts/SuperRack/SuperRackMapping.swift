import Foundation

/// SuperRack's MIDI Controller mapping file (`.mrrc`, Import/Export in the MIDI Controller
/// window), written in the shape SuperRack Performer 15.15.12.13 exports.
public enum SuperRackMapping {
    public static func mrrc(channel: Int, ccBase: Int,
                            version: String = "15.15.12.13 Build 288878") -> String {
        var s = """
        <MultiRackRemoteControl>
         <DisplayMTC>false</DisplayMTC>
         <FollowProgramChange>false</FollowProgramChange>
         <UseCCForScenesControl>false</UseCCForScenesControl>
         <GenerateProgramChange>false</GenerateProgramChange>
         <FollowMixer1>true</FollowMixer1>
         <MIDITakeover>false</MIDITakeover>
         <ScenesInputChannel>-1</ScenesInputChannel>
         <FileVersion>1.0.0.0</FileVersion>
         <MultiRackVersion>\(version)</MultiRackVersion>
         <Commands>
          <NumberOfCommands>\(NavCommand.allCases.count)</NumberOfCommands>

        """
        for c in NavCommand.allCases {
            s += """
              <Command>
               <Name>\(c.superRackName)</Name>
               <RelativeMode>0</RelativeMode>
               <MIDI>
                <MessageType>Control Change</MessageType>
                <Channel>\(hex(channel - 1))</Channel>
                <Number>\(hex(ccBase + c.rawValue))</Number>
                <Param>-2</Param>
                <BigNumber>0x00</BigNumber>
               </MIDI>
              </Command>

            """
        }
        s += """
         </Commands>
        </MultiRackRemoteControl>

        """
        return s
    }

    private static func hex(_ v: Int) -> String { String(format: "0x%02X", v) }
}
