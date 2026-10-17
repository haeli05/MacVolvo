import SwiftUI
import AppKit

/// Settings' categories, in tabs across the top: everyday choices first, rarely needed ones in
/// Advanced. Settings reopens on the tab shown last (AppModel.settingsTab).
enum SettingsTab:String, CaseIterable, Identifiable {
    case general, display, graphics, audio, advanced
    var id:String { rawValue }
    var title:String { rawValue.capitalized }
    var symbol:String {
        switch self {
        case .general: return "gearshape"
        case .display: return "display"
        case .graphics: return "cube"
        case .audio: return "speaker.wave.2"
        case .advanced: return "gearshape.2"
        }
    }
}
/// The same game launch choices on Play and in Settings. Desktop modes and a
/// custom size supplement the common game resolutions without losing saved sizes.
struct LaunchResolutionPicker:View {
    let gameName:String
    let resolution:DisplayResolution
    let main:MainDisplay?
    var disabled=false
    let choose:(DisplayResolution)->Void
    @State private var showCustom=false
    @State private var width=""
    @State private var height=""
    private var custom:DisplayResolution? { DisplayResolution.parsed(width:width,height:height) }
    var body:some View {
        Menu {
            ForEach(DisplayResolution.grouped(DisplayResolution.choices(on:main,keeping:resolution))) { group in
                Menu(group.aspect) {
                    ForEach(group.resolutions,id:\.self) { option in
                        Button { choose(option) } label: {
                            if option == resolution { Label(option.label,systemImage:"checkmark") }
                            else { Text(option.label) }
                        }
                    }
                }
            }
            Divider()
            Button("Custom resolution…") {
                width=String(resolution.width);height=String(resolution.height);showCustom=true
            }
        } label: {
            Text("\(resolution.label) · \(resolution.aspect)").monospacedDigit()
        }.menuStyle(.borderedButton).controlSize(.small).disabled(disabled)
            .accessibilityLabel("\(gameName) launch resolution, \(resolution.label), \(resolution.aspect)")
            .sheet(isPresented:$showCustom) {
                VStack(alignment:.leading,spacing:16) {
                    Text("\(gameName) resolution").font(LauncherStyle.font(20,.semibold))
                    HStack {
                        TextField("Width",text:$width).accessibilityLabel("Width in pixels")
                        Text("×")
                        TextField("Height",text:$height).accessibilityLabel("Height in pixels")
                    }.textFieldStyle(.roundedBorder)
                    Text("Width: 640–16384 pixels. Height: 480–16384 pixels.")
                        .font(LauncherStyle.font(12)).foregroundStyle(.secondary)
                    if let custom {
                        Text(main?.caption(for:custom) ?? "\(custom.aspect) · Applies the next time this game starts.")
                            .font(LauncherStyle.font(13)).fixedSize(horizontal:false,vertical:true)
                    }
                    HStack {
                        Spacer()
                        Button("Cancel") { showCustom=false }.keyboardShortcut(.cancelAction)
                        Button("Save") {
                            if let custom { choose(custom);showCustom=false }
                        }.keyboardShortcut(.defaultAction).disabled(custom == nil || disabled)
                    }
                }.padding(24).frame(width:420).font(LauncherStyle.font(14))
            }
    }
}
// Updates, the display setting the app owns, what Steam and the games start with, and
// recovery actions, in tabs. Driver tuning is deliberately absent: FPS, quality and
// sensitivity live in the games.
struct SettingsSheet:View {
    @Bindable var model:AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var confirmForceQuit=false
    @State private var confirmRepair=false
    @State private var confirmResetDisplay=false
    /// Follows System Settings: the main display can change while Settings is open.
    @State private var main=MainDisplay.current
    /// Also follows System Settings, where the player turns the microphone on or off.
    @State private var microphoneAccess=Microphone.access
    var body:some View {
        VStack(spacing:16) {
            LauncherHeading(title:"Settings",subtitle:"",compact:true)
            tabs
            ScrollView { VStack(spacing:12) { page } }
                .scrollIndicators(.hidden).frame(maxHeight:560)
            if !model.notice.isEmpty { LauncherNotice(text:model.notice) }
            HStack {
                // Uninstall lives here, always visible and apart from the
                // everyday settings; it opens its own confirmation.
                Button(role:.destructive) { model.sheet = .uninstall } label: {
                    Label("Uninstall \(Brand.name)…",systemImage:"trash").font(LauncherStyle.font(13,.medium))
                }.buttonStyle(.borderless).foregroundStyle(.red).disabled(model.uninstall == .working)
                    .help("Move \(Brand.name), Steam and your games to the Trash")
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.large).keyboardShortcut(.cancelAction)
            }
        }.font(LauncherStyle.font(14)).padding(.horizontal,32).padding(.vertical,28).frame(width:540)
            .tint(.primary).background { LauncherBackground() }
            .onReceive(NotificationCenter.default.publisher(for:NSApplication.didChangeScreenParametersNotification)) { _ in
                main=MainDisplay.current
                model.refreshDisplay()
            }
            // Steam or a game may have opened or closed while the player was away,
            // and the microphone been turned on or off in System Settings.
            .onAppear { model.checkRunning() }
            .onReceive(NotificationCenter.default.publisher(for:NSApplication.didBecomeActiveNotification)) { _ in
                model.checkRunning();microphoneAccess=Microphone.access
            }
            .alert("Force quit your game and Steam?",isPresented:$confirmForceQuit) {
                Button("Cancel",role:.cancel) {}
                Button("Force Quit",role:.destructive,action:model.forceQuit)
            } message: { Text("Use this when the game stops responding. If you’re in a match, you’ll leave it.") }
            .alert("Repair game files?",isPresented:$confirmRepair) {
                Button("Cancel",role:.cancel) {}
                Button("Repair",action:model.repair)
            } message: { Text("Steam and your games must be closed. This reinstalls the files this app adds and refreshes the Windows environment. Your games, their settings and your Steam sign-in are kept.") }
            .alert("Reset \(model.selectedGame.title) display settings?",isPresented:$confirmResetDisplay) {
                Button("Cancel",role:.cancel) {}
                Button("Reset",action:model.resetDisplay)
            } message: { Text("\(model.selectedGame.title) will open at \(DisplayResolution.initial(for:main).label) the next time it starts. Your graphics quality and FPS settings stay as they are.") }
    }
    /// The categories, each an icon above its name, like the toolbar of a Mac app's Settings.
    private var tabs:some View {
        HStack(spacing:6) {
            ForEach(SettingsTab.allCases) { tab in
                let selected=model.settingsTab == tab
                let shape=RoundedRectangle(cornerRadius:14,style:.continuous)
                Button { model.settingsTab=tab } label: {
                    VStack(spacing:5) {
                        Image(systemName:tab.symbol).font(.system(size:17,weight:.medium)).frame(height:21)
                            .foregroundStyle(selected ? AnyShapeStyle(LauncherStyle.accent) : AnyShapeStyle(.secondary))
                        Text(tab.title).font(LauncherStyle.font(12,selected ? .semibold : .medium))
                            .foregroundStyle(selected ? .primary : .secondary)
                    }.frame(width:78,height:54)
                        .background {
                            if selected {
                                shape.fill(LauncherStyle.surface(scheme)).overlay { shape.strokeBorder(.primary.opacity(0.05),lineWidth:1) }
                            }
                        }.contentShape(shape)
                }.buttonStyle(.plain).accessibilityLabel(tab.title).accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
    @ViewBuilder private var page:some View {
        switch model.settingsTab {
        case .general:
            if Brand.allowsUpdates { updates }
            steam
        case .display:
            display
            resetDisplay
        case .graphics:
            metalHUD
        case .audio:
            microphone
            sound
        case .advanced:
            troubleshooting
            advanced
        }
    }
    private var updates:some View {
        LauncherPanel(inset:16) {
            VStack(alignment:.leading,spacing:6) {
                HStack(alignment:.center,spacing:12) {
                    VStack(alignment:.leading,spacing:2) {
                        Text("Updates").font(LauncherStyle.font(14,.semibold))
                        Text("\(status) · Nothing about you or your Mac is sent.").font(LauncherStyle.font(12))
                            .foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    }
                    Spacer(minLength:12)
                    if case .available=model.update {
                        Button("Update…") { model.sheet = .update }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(LauncherStyle.accent)
                            .foregroundStyle(LauncherStyle.ink)
                    } else {
                        Button("Check Now") { model.checkForUpdates(manual:true,present:false) }.buttonStyle(.bordered).buttonBorderShape(.capsule)
                            .disabled(model.update == .checking || model.update == .installing)
                    }
                }
                Divider().padding(.vertical,6)
                SettingSwitch(title:"Check for updates automatically",isOn:$model.automaticUpdates)
            }
        }
    }
    private var status:String {
        switch model.update {
        case .available(let item): return "Version \(item.version) is available"
        case .upToDate: return "Version \(UpdateCheck.installed) · up to date"
        case .checking: return "Checking…"
        case .downloading, .installing: return "Updating…"
        case .failed: return "Couldn’t reach GitHub; check your connection"
        default: return "Version \(UpdateCheck.installed)"
        }
    }
    private var steam:some View {
        LauncherPanel(inset:16) {
            SettingSwitch(title:"Open Steam when \(Brand.name) opens",detail:"Turn off to start Steam yourself with Open Steam.",
                          isOn:$model.autoOpenSteam)
        }
    }
    /// Each game's launch size and fullscreen mode are also saved for Steam's Play button.
    private var display:some View {
        LauncherPanel(inset:16) {
            VStack(alignment:.leading,spacing:12) {
                HStack(alignment:.center,spacing:12) {
                    VStack(alignment:.leading,spacing:2) {
                        Text("Game launch options").font(LauncherStyle.font(14,.semibold))
                        Text("Choose a resolution and window mode for each game.")
                            .font(LauncherStyle.font(12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    }
                    Spacer(minLength:8)
                }.accessibilityElement(children:.combine)
                displayOptions
            }
        }
    }
    private var displayOptions:some View {
        return VStack(alignment:.leading,spacing:12) {
            if let main {
                mainDisplay(main)
                if let note=main.scalingNote {
                    LauncherNotice(text:note,symbol:"exclamationmark.triangle",action:("Open Display Settings",Self.openDisplaySettings))
                }
            }
            Text("Games open on the main display, the one with the menu bar. To use another, choose Displays… and set it as the main display.")
                .font(LauncherStyle.font(13)).lineSpacing(3).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            ForEach(AppModel.Game.allCases) { game in
                VStack(alignment:.leading,spacing:8) {
                    HStack {
                        Text(game.title).font(LauncherStyle.font(14,.semibold))
                        Spacer()
                        if model.savedGameOptions.contains(game) {
                            Label("Saved",systemImage:"checkmark.circle.fill").font(LauncherStyle.font(12)).foregroundStyle(.green)
                        }
                    }
                    HStack {
                        LaunchResolutionPicker(gameName:game.title,resolution:model.resolution(for:game),main:main,
                                               disabled:model.busy || model.running == .game) { model.chooseResolution($0,for:game) }
                        Spacer(minLength:8)
                        Toggle("Fullscreen",isOn:Binding(get:{ model.fullscreen(game) },set:{ model.setFullscreen(game,$0) }))
                            .toggleStyle(.switch).controlSize(.small).disabled(model.busy || model.running == .game)
                    }
                    Text(main?.caption(for:model.resolution(for:game)) ?? "Smaller resolutions run faster; larger ones look sharper.")
                        .font(LauncherStyle.font(12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    if game != AppModel.Game.allCases.last { Divider().padding(.top,4) }
                }
            }
            Text(model.running == .game ? "Close your game to change its launch options." : "Changes save as you choose. Start the game through MacVolvo once to apply them to Steam Properties too.")
                .font(LauncherStyle.font(12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            Divider().padding(.vertical,2)
            SettingSwitch(title:"Remember a resolution for each display",detail:"Applies to the default size until you choose a resolution for a game.",
                          isOn:Binding(get:{ model.rememberEachDisplay },set:{ model.setRememberEachDisplay($0) }),disabled:model.busy)
        }
    }
    private func mainDisplay(_ main:MainDisplay) -> some View {
        HStack(spacing:12) {
            Image(systemName:main.builtIn ? "laptopcomputer" : "display").font(.system(size:20)).foregroundStyle(.secondary).frame(width:30)
            VStack(alignment:.leading,spacing:2) {
                Text(main.name).font(LauncherStyle.font(14,.medium)).lineLimit(1)
                Text("Main display · \(main.size) · \(main.aspect)").font(LauncherStyle.font(12)).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength:8)
            Button("Displays…",action:Self.openDisplaySettings).buttonStyle(.bordered).buttonBorderShape(.capsule).help("Open System Settings › Displays")
        }.padding(12).background(.primary.opacity(0.04),in:RoundedRectangle(cornerRadius:14,style:.continuous))
            .accessibilityElement(children:.combine)
    }
    static func openDisplaySettings() {
        NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.Displays-Settings.extension")!)
    }
    private var resetDisplay:some View {
        LauncherPanel(inset:16) {
            action("Reset \(model.selectedGame.title) Display…",detail:"If this game opens to a black screen or at the wrong size.",button:"Reset") { confirmResetDisplay=true }
        }
    }
    /// The game gets the HUD from Steam, which starts it; so the switch changes only
    /// while Steam is closed, and Settings offers to close it.
    private var metalHUD:some View {
        LauncherPanel(inset:16) {
            VStack(alignment:.leading,spacing:6) {
                SettingSwitch(title:"Metal Performance HUD",
                              detail:"Shows Apple’s performance overlay in your game: FPS, frame times, and when your Mac is compiling shaders, the cause of first-match stutters.",
                              isOn:$model.metalHUD,disabled:model.running != nil)
                if let running=model.running { closeFirst(running,"this") }
            }
        }
    }
    /// A setting Steam carries from when it opens: change it once it's closed.
    private func closeFirst(_ running:AppModel.Running, _ what:String) -> some View {
        HStack(spacing:12) {
            Text(running == .game ? "Quit your game to change \(what)." : "Close Steam to change \(what).")
                .font(LauncherStyle.font(12,.medium)).fixedSize(horizontal:false,vertical:true)
            Spacer(minLength:8)
            if running == .client {
                Button("Close Steam",action:model.closeSteam).buttonStyle(.bordered).buttonBorderShape(.capsule).disabled(model.busy)
            }
        }.padding(.top,6)
    }
    /// macOS lets only the player switch the permission, in System Settings, which then
    /// asks to reopen the app; the button opens that switch (or, before the first answer,
    /// shows macOS's prompt). With Bluetooth headphones the worker picks the Mac's own
    /// microphone at launch (portable_voice.h).
    private var microphone:some View {
        LauncherPanel(inset:16) {
            VStack(alignment:.leading,spacing:6) {
                HStack(alignment:.center,spacing:12) {
                    VStack(alignment:.leading,spacing:2) {
                        Text("Microphone").font(LauncherStyle.font(14,.semibold))
                        Text(microphoneDetail).font(LauncherStyle.font(12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    }
                    Spacer(minLength:12)
                    Button(microphoneAccess == .allowed ? "Turn Off…" : microphoneAccess == .denied ? "Turn On…" : "Allow…") {
                        guard microphoneAccess == .undecided else { NSWorkspace.shared.open(Microphone.privacySettings);return }
                        Task { await Microphone.ask();microphoneAccess=Microphone.access }
                    }.buttonStyle(.bordered).buttonBorderShape(.capsule)
                        .help(microphoneAccess == .undecided ? "Shows macOS’s microphone prompt" : "Opens Privacy & Security › Microphone in System Settings")
                }
                Divider().padding(.vertical,6)
                note("Bluetooth headphones","With AirPods or other Bluetooth headphones, voice chat uses your Mac’s built-in microphone when it’s available. Their own microphone would switch them to a lower-quality mode for all sound.")
            }
        }
    }
    private var microphoneDetail:String {
        switch microphoneAccess {
        case .allowed: return "On. Your team can hear you in voice chat."
        case .denied: return "Off. Your team can’t hear you in voice chat."
        case .undecided: return "Lets your team hear you in voice chat."
        }
    }
    /// Wine picks the sound output once, as the game starts, and keeps it.
    private var sound:some View {
        LauncherPanel(inset:16) {
            VStack(alignment:.leading,spacing:12) {
                note("Speakers and headphones","Your game keeps the sound output that was selected when it started. Connect your headphones and select them on your Mac before you press Play; to switch later, quit the game and play again.")
                note("Crackling audio","Open Audio MIDI Setup, select your output device, then set Format to 96,000 Hz (96 kHz), if supported. Quit and restart the game afterward. This helped on the tested M2 Max.")
            }
        }
    }
    private func note(_ title:String,_ text:String) -> some View {
        VStack(alignment:.leading,spacing:2) {
            Text(title).font(LauncherStyle.font(14,.semibold))
            Text(text).font(LauncherStyle.font(12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
        }.accessibilityElement(children:.combine)
    }
    private var troubleshooting:some View {
        LauncherPanel(inset:16) {
            VStack(alignment:.leading,spacing:10) {
                Text("Troubleshooting").font(LauncherStyle.font(14,.semibold))
                action("Force Quit Game & Steam",detail:"If the game stops responding.",button:"Force Quit") { confirmForceQuit=true }
                action("Repair Game Files…",detail:"If Steam or a game won’t start. Takes a minute or two.",button:"Repair") { confirmRepair=true }
            }
        }
    }
    private func action(_ title:String, detail:String, button:String, _ perform:@escaping ()->Void) -> some View {
        HStack(alignment:.center,spacing:12) {
            VStack(alignment:.leading,spacing:2) {
                Text(title).font(LauncherStyle.font(14,.medium))
                Text(detail).font(LauncherStyle.font(12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            }
            Spacer(minLength:12)
            Button(button,action:perform).buttonStyle(.bordered).buttonBorderShape(.capsule)
                .disabled(model.busy || !model.clientInstalled)
        }
    }
    /// Rarely needed: a network that hands out its proxy automatically (MacVolvo connects
    /// directly, Recall issue #15). Steam and the games carry it from when they start.
    private var advanced:some View {
        let locked=model.running != nil || !model.canChangeAdvanced
        return LauncherPanel(inset:16) {
            VStack(alignment:.leading,spacing:6) {
                SettingSwitch(title:"Detect network proxy automatically",detail:"Only needed on some work or school networks.",
                              isOn:Binding(get:{ model.proxyAutoDetect },set:{ model.setAdvanced(.proxyAutoDetect,$0) }),disabled:locked)
                if let running=model.running { closeFirst(running,"this") }
            }
        }
    }
}
/// A setting with its switch at the trailing edge, as in System Settings: title (and anything
/// beside it, such as New) over an optional explanation.
private struct SettingSwitch<Accessory:View>:View {
    let title:String
    var detail:String?=nil
    @Binding var isOn:Bool
    var disabled=false
    @ViewBuilder var accessory:Accessory
    var body:some View {
        HStack(alignment:.center,spacing:12) {
            VStack(alignment:.leading,spacing:2) {
                HStack(spacing:8) {
                    Text(title).font(LauncherStyle.font(14,.semibold))
                    accessory
                }
                if let detail {
                    Text(detail).font(LauncherStyle.font(12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                }
            }
            Spacer(minLength:12)
            Toggle(title,isOn:$isOn).labelsHidden().toggleStyle(.switch).tint(LauncherStyle.accent).disabled(disabled)
                .accessibilityHint(detail ?? "")
        }
    }
}
extension SettingSwitch where Accessory == EmptyView {
    init(title:String, detail:String?=nil, isOn:Binding<Bool>, disabled:Bool=false) {
        self.init(title:title,detail:detail,isOn:isOn,disabled:disabled) { EmptyView() }
    }
}
struct HelpSheet:View {
    @Bindable var model:AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var reportExpanded=false
    @State private var expanded=Set<Int>()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let questions:[(question:String, answer:String)]=[
        ("How do I install Counter-Strike 2 or Deadlock?","Choose Open Steam and sign in with your Steam account. Find the game in your Library or the Store and click Install. Once it’s installed, choose it on \(Brand.name)’s Play screen."),
        ("Why does the game stutter?","First-use shader compilation can cause stutters. Persistent CS2 combat spikes and severe FPS drops are still under investigation; repeated stutters are not necessarily shader compilation."),
        ("How do I play on an external monitor?","Games open on your main display, the one with the menu bar. In System Settings › Displays, select the monitor and set Use as to Main display. Choose each game’s resolution in Settings › Display, then start it through \(Brand.name) to sync Steam Properties. Sizes that exceed the main display are fitted for that launch."),
        ("Which resolution should I choose?","Your display’s own resolution gives the sharpest picture; a smaller one runs faster and is scaled up to fill the screen. Change it in the game’s Video settings, or in Settings › Display, which shows what each size looks like on your main display."),
        ("Black screen with music on launch","Quit the game completely, then launch it again. This intermittent issue can occur from MacVolvo or Steam and is still being investigated."),
        ("The game opens at the wrong size","Quit the game, choose Settings › Display › Reset Display Settings, then play again. The game opens at 1080p; your graphics and FPS settings stay as they are."),
        ("I can’t find the game window","Select the game or Steam in the Dock. If it’s still hidden, check your other desktops."),
        ("Steam shows a blank window","Close Steam, then open it again from \(Brand.name) rather than from the Dock: \(Brand.name) opens it with the display settings its window needs."),
        ("The game stopped responding","Choose Settings › Advanced › Force Quit, then play again. If it still won’t start, choose Settings › Advanced › Repair Game Files."),
        ("Steam can’t connect on a work or school network","Some of these networks set up their proxy automatically. Close Steam, turn on Settings › Advanced › Detect network proxy automatically, then open Steam again from \(Brand.name)."),
        ("My team can’t hear me","Open Settings › Audio. If the microphone is off, choose Turn On…, switch on \(Brand.name) in System Settings, then open \(Brand.name) again. Then check the voice settings in the game’s Audio options."),
        ("Which Macs can play?","Macs with Apple silicon on macOS 26.5 or later, with Rosetta. 16 GB of memory is recommended, and a new installation needs about 70 GB per game of storage."),
        ("How do I uninstall?","Choose Settings › Uninstall \(Brand.name). \(Brand.name), Steam and your games move to the Trash; your Steam account isn’t affected."),
        ("Found a bug?","Choose Report a Problem to open an issue on GitHub, and attach a support report (below): it lists your setup, never account details."),
    ]
    var body:some View {
        VStack(spacing:24) {
            LauncherHeading(title:"Help & FAQ",subtitle:"Quick answers to common questions.",compact:true)
            ScrollView {
                VStack(spacing:16) {
                    LauncherPanel(inset:0) {
                        VStack(spacing:0) {
                            ForEach(questions.indices,id:\.self) { index in
                                if index>0 { Divider().padding(.horizontal,20) }
                                question(index)
                            }
                        }
                    }
                    LauncherPanel(inset:0) {
                        VStack(spacing:0) {
                            Button {
                                withAnimation(reduceMotion ? nil : .easeInOut(duration:0.18)) { reportExpanded.toggle() }
                            } label: {
                                HStack {
                                    Text("Support report").font(LauncherStyle.font(15,.semibold))
                                    Spacer()
                                    Image(systemName:reportExpanded ? "chevron.up" : "chevron.down")
                                        .font(.system(size:12,weight:.semibold)).foregroundStyle(.secondary)
                                }.padding(20).frame(maxWidth:.infinity).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityValue(reportExpanded ? "Expanded" : "Collapsed")
                                .accessibilityHint("Show or hide the report preview")
                            if reportExpanded {
                            VStack(alignment:.leading,spacing:16) {
                                Text("Review exactly what will be saved. Nothing is uploaded.")
                                    .font(LauncherStyle.font(13)).foregroundStyle(.secondary)
                                Text(model.report).font(LauncherStyle.font(12)).textSelection(.enabled)
                                    .frame(maxWidth:.infinity,alignment:.leading).accessibilityLabel("Support report preview")
                                HStack {
                                    Button("Refresh",action:model.makeReport).buttonStyle(.borderless)
                                    Spacer()
                                    Button("Save Report…",action:model.saveReport).buttonStyle(.bordered).buttonBorderShape(.capsule)
                                }
                            }.padding(.horizontal,20).padding(.bottom,20)
                            }
                        }
                    }
                    RepositoryLink()
                }
            }.scrollIndicators(.hidden)
            HStack {
                Link(destination:Brand.issues) {
                    Label("Report a Problem",systemImage:"exclamationmark.bubble").font(LauncherStyle.font(13,.medium))
                }.buttonStyle(.borderless).help("Open a new issue on GitHub in your browser")
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.large).keyboardShortcut(.defaultAction)
            }
        }.font(LauncherStyle.font(14)).padding(32).frame(width:540,height:660)
            .tint(.primary).background { LauncherBackground() }
    }
    private func question(_ index:Int)->some View {
        let open=expanded.contains(index)
        return VStack(alignment:.leading,spacing:0) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration:0.16)) { if open { expanded.remove(index) } else { expanded.insert(index) } }
            } label: {
                HStack(spacing:12) {
                    Text(questions[index].question).font(LauncherStyle.font(14,.semibold)).multilineTextAlignment(.leading)
                    Spacer(minLength:8)
                    Image(systemName:"chevron.down").font(.system(size:11,weight:.semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(open ? 180 : 0)).accessibilityHidden(true)
                }.padding(.horizontal,20).padding(.vertical,14).frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityValue(open ? "Expanded" : "Collapsed")
            if open {
                Text(questions[index].answer).font(LauncherStyle.font(13)).lineSpacing(3).foregroundStyle(.secondary)
                    .fixedSize(horizontal:false,vertical:true).textSelection(.enabled)
                    .padding(.horizontal,20).padding(.bottom,16)
            }
        }
    }
}
struct AboutSheet:View {
    @Bindable var model:AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var licenses=false
    private var version:String {
        "Version \(UpdateCheck.installed) · Build \(UpdateCheck.build)" + (model.release?.distribution == "private-preview" ? " · Private alpha" : "")
    }
    var body:some View {
        VStack(alignment:.leading,spacing:22) {
            HStack(alignment:.center,spacing:18) {
                AppArtwork(size:76)
                VStack(alignment:.leading,spacing:4) {
                    Text(Brand.name).font(LauncherStyle.font(30,.bold)).tracking(-0.8).accessibilityAddTraits(.isHeader)
                    Text(Brand.tagline).font(LauncherStyle.font(14)).foregroundStyle(.secondary)
                    Text(version).font(LauncherStyle.font(11)).foregroundStyle(.secondary)
                }
            }
            HStack(spacing:12) {
                RepositoryLink(compact:true)
                VStack(alignment:.leading,spacing:3) {
                    Text("Open source. Contributions welcome.").foregroundStyle(.secondary)
                    Button("Licenses") { licenses=true }.buttonStyle(.plain).underline()
                        .foregroundStyle(.secondary).help("Show \(Brand.name)’s license and notices")
                }.font(LauncherStyle.font(12))
            }
            LauncherPanel {
                VStack(alignment:.leading,spacing:10) {
                    Text("Credits").font(LauncherStyle.font(15,.semibold)).accessibilityAddTraits(.isHeader)
                    AuthorLink()
                    Text("\(Brand.name) runs Counter-Strike 2 and Deadlock through Steam on the Wine engine, Metal translation and setup that Recall built for Overwatch.")
                        .font(LauncherStyle.font(13)).lineSpacing(3).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    UpstreamLink()
                }
            }
            Spacer(minLength:0)
            HStack(alignment:.bottom,spacing:20) {
                Text(Brand.trademarks).font(LauncherStyle.font(10.5)).lineSpacing(1).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                Spacer(minLength:0)
                Button("Done") { dismiss() }.buttonStyle(.bordered).buttonBorderShape(.capsule)
                    .controlSize(.large).keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width:520,alignment:.top).tint(.primary)
            .background(LauncherStyle.ground(scheme))
            .sheet(isPresented:$licenses) { LicensesSheet() }
    }
}
/// The project's own NOTICE and Apache 2.0 license as bundled, and a way to the third-party ones.
struct LicensesSheet:View {
    @Environment(\.dismiss) private var dismiss
    private static func bundled(_ name:String,_ type:String)->String {
        Bundle.main.url(forResource:name,withExtension:type).flatMap { try? String(contentsOf:$0,encoding:.utf8) } ?? ""
    }
    private let text=[bundled("NOTICE","txt"),bundled("PROJECT-LICENSE","txt")]
        .map { $0.trimmingCharacters(in:.newlines) }.filter { !$0.isEmpty }.joined(separator:"\n\n\n")
    private var thirdParty:URL? { Bundle.main.url(forResource:"Licenses",withExtension:nil) }
    var body:some View {
        VStack(spacing:24) {
            SheetHero(symbol:"doc.text",title:"Licenses",
                      subtitle:"\(Brand.name) is open source under the Apache License 2.0. Wine, DXMT and the other components it includes keep their own licenses.")
            LauncherPanel {
                ScrollView {
                    Text(text.isEmpty ? "The license files are missing from this copy of \(Brand.name)." : text)
                        .font(.system(size:10.5,design:.monospaced)).lineSpacing(2).textSelection(.enabled)
                        .frame(maxWidth:.infinity,alignment:.leading)
                }.frame(height:340)
            }
            HStack(spacing:16) {
                if let thirdParty {
                    Button("Third-Party Licenses") { NSWorkspace.shared.activateFileViewerSelecting([thirdParty]) }
                        .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.large)
                        .help("Show the bundled third-party license files in Finder")
                }
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.bordered).buttonBorderShape(.capsule)
                    .controlSize(.large).keyboardShortcut(.defaultAction)
            }
        }.font(LauncherStyle.font(14)).padding(32).frame(width:660)
            .tint(.primary).background { LauncherBackground() }
    }
}
struct UninstallSheet:View {
    @Bindable var model:AppModel
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        VStack(spacing:24) {
            switch model.uninstall {
            case .idle, .failed:
                SheetHero(symbol:"trash",title:"Uninstall \(Brand.name)?",subtitle:"This removes your games, Steam and \(Brand.name) from your Mac.")
                LauncherPanel {
                    VStack(alignment:.leading,spacing:14) {
                        Text("What will be moved to the Trash").font(LauncherStyle.font(14,.semibold))
                        VStack(alignment:.leading,spacing:8) {
                            row("Games", "Counter-Strike 2, Deadlock and their settings")
                            row("Steam", "The Steam app set up by this app")
                            row(Brand.name, "This app and its setup files")
                        }
                        Divider()
                        Text("Your Steam account and any other copy of Steam on this Mac are not touched. Everything goes to the Trash, so you can put it back from Finder. Storage is freed once you empty the Trash.")
                            .font(LauncherStyle.font(13)).lineSpacing(3).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    }
                }
                if case .failed(let message)=model.uninstall { LauncherNotice(text:message) }
                else { LauncherNotice(text:"Steam is closed for you if it’s open. Your game itself must be quit first. Nothing is removed until you choose Uninstall.") }
                HStack(spacing:16) {
                    Button("Cancel") { model.uninstall = .idle;dismiss() }.buttonStyle(.bordered).buttonBorderShape(.capsule)
                        .controlSize(.large).keyboardShortcut(.cancelAction)
                    Spacer()
                    // Deliberately not the default action: Return never uninstalls.
                    Button(role:.destructive) { model.uninstallEverything() } label: { Text("Uninstall").font(LauncherStyle.font(15,.semibold)).padding(.horizontal,8) }
                        .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.large).tint(.red)
                }
            case .working:
                SheetHero(symbol:"trash",title:"Uninstalling",subtitle:model.stage == "Closing Steam" ? "Closing Steam first." : "Moving your games, Steam and this app to the Trash.")
                ProgressView().controlSize(.small).accessibilityLabel("Uninstalling")
            case .done(let appRemoved):
                SheetHero(symbol:"checkmark",title:"Uninstalled",subtitle:appRemoved ? "Your games, Steam and this app are in the Trash." : "Your games and Steam are in the Trash.")
                LauncherNotice(text:appRemoved ? "Empty the Trash to free the storage. Quit to finish." : "\(Brand.name) couldn’t move itself to the Trash. Quit, then drag \(Brand.name) from Applications to the Trash and empty it.")
                Button("Quit") { model.quit() }.buttonStyle(.bordered).buttonBorderShape(.capsule)
                    .controlSize(.large).keyboardShortcut(.defaultAction)
            }
        }.font(LauncherStyle.font(14)).padding(32).frame(width:520)
            .tint(.primary).background { LauncherBackground() }
    }
    private func row(_ name:String,_ detail:String)->some View {
        HStack(alignment:.firstTextBaseline,spacing:12) {
            Text(name).font(LauncherStyle.font(13,.semibold)).frame(width:130,alignment:.leading)
            Text(detail).font(LauncherStyle.font(13)).foregroundStyle(.secondary)
        }
    }
}
// Every update outcome in one place: a check in progress, the newer version
// with its notes, the download, or why nothing changed.
struct UpdateSheet:View {
    @Bindable var model:AppModel
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        VStack(spacing:24) {
            switch model.update {
            case .available(let item):
                SheetHero(symbol:"arrow.down.circle",title:"Update available",subtitle:"\(Brand.name) \(item.version) is ready to install. You have \(UpdateCheck.installed).")
                LauncherPanel {
                    VStack(alignment:.leading,spacing:10) {
                        Text("What’s new").font(LauncherStyle.font(14,.semibold))
                        if item.notes.isEmpty {
                            Text("See the release notes for details.").font(LauncherStyle.font(13)).foregroundStyle(.secondary)
                        }
                        ForEach(item.notes.indices,id:\.self) { index in
                            HStack(alignment:.firstTextBaseline,spacing:8) {
                                Text("•").foregroundStyle(.secondary)
                                Text(item.notes[index]).lineSpacing(3).fixedSize(horizontal:false,vertical:true)
                            }.font(LauncherStyle.font(13))
                        }
                    }
                }
                if !model.updateNotice.isEmpty { LauncherNotice(text:model.updateNotice,symbol:"exclamationmark.triangle") }
                Text("Your games, settings and Steam sign-in are kept. The app reopens when it’s done.")
                    .font(LauncherStyle.font(12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                HStack(spacing:16) {
                    Button("Later") { dismiss() }.buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.large).keyboardShortcut(.cancelAction)
                    Link("Release Notes",destination:item.page).font(LauncherStyle.font(13))
                    Spacer()
                    LauncherPrimaryAction(title:"Update Now",action:model.installUpdate).keyboardShortcut(.defaultAction).disabled(model.busy)
                }
            case .downloading(let fraction):
                SheetHero(symbol:"arrow.down.circle",title:"Downloading the update",subtitle:"\(Int(fraction*100))% · The app reopens when it’s done.")
                ProgressView(value:fraction).frame(maxWidth:360).accessibilityLabel("Download progress")
                Button("Cancel",action:model.cancelUpdateDownload).buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.large)
            case .installing:
                SheetHero(symbol:"arrow.down.circle",title:"Installing the update",subtitle:"The app will reopen in a moment.")
                ProgressView().controlSize(.small).accessibilityLabel("Installing")
            case .upToDate:
                SheetHero(symbol:"checkmark",title:"You’re up to date",subtitle:"\(Brand.name) \(UpdateCheck.installed) is the latest version.")
                Button("Done") { dismiss() }.buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.large).keyboardShortcut(.defaultAction)
            case .failed(let message):
                SheetHero(symbol:"exclamationmark",title:"Couldn’t check for updates",subtitle:message)
                HStack(spacing:16) {
                    Button("Done") { dismiss() }.buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.large).keyboardShortcut(.cancelAction)
                    Spacer()
                    LauncherPrimaryAction(title:"Try Again") { model.checkForUpdates(manual:true) }.keyboardShortcut(.defaultAction)
                }
            case .checking, .idle:
                SheetHero(symbol:"arrow.triangle.2.circlepath",title:"Checking for updates",subtitle:"Asking GitHub for the latest version.")
                ProgressView().controlSize(.small).accessibilityLabel("Checking for updates")
                Button("Cancel") { dismiss() }.buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.large).keyboardShortcut(.cancelAction)
            }
        }.font(LauncherStyle.font(14)).padding(32).frame(width:520)
            .tint(.primary).background { LauncherBackground() }
    }
}
struct WhatsNewSheet:View {
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        VStack(spacing:24) {
            SheetHero(symbol:"sparkles",title:"What’s new in \(WhatsNew.version)",subtitle:"\(Brand.name) \(UpdateCheck.installed)")
            LauncherPanel {
                VStack(alignment:.leading,spacing:16) {
                    ForEach(WhatsNew.items.indices,id:\.self) { index in
                        let item=WhatsNew.items[index]
                        HStack(alignment:.top,spacing:14) {
                            Image(systemName:item.symbol).font(.system(size:17,weight:.medium)).foregroundStyle(LauncherStyle.accent)
                                .frame(width:24).accessibilityHidden(true)
                            VStack(alignment:.leading,spacing:3) {
                                Text(item.title).font(LauncherStyle.font(14,.semibold))
                                Text(item.detail).font(LauncherStyle.font(13)).lineSpacing(2).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                            }
                        }
                    }
                }
            }
            HStack(spacing:16) {
                Link("Release Notes",destination:Brand.releases).font(LauncherStyle.font(13))
                Spacer()
                LauncherPrimaryAction(title:"Continue") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.font(LauncherStyle.font(14)).padding(32).frame(width:520)
            .tint(.primary).background { LauncherBackground() }
    }
}
