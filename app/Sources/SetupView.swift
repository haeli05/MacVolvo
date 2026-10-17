import SwiftUI
import AppKit

struct SetupView: View {
    @Bindable var model:AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body:some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing:0) {
                    VStack(spacing:24) {
                        if model.screen == .welcome {
                            VStack(spacing:18) {
                                Wordmark(height:84)
                                Text(subtitle).font(LauncherStyle.font(16)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            }
                        } else {
                            VStack(spacing:6) {
                                Wordmark(height:84,badge:model.screen == .failure ? (model.failure.code == "cancelled" ? "pause.fill" : "exclamationmark") : (model.screen == .driveMissing ? "externaldrive" : nil))
                            }
                            LauncherHeading(title:model.title,subtitle:subtitle)
                        }
                        details
                        VStack(spacing:12) { actions }
                        if !model.notice.isEmpty { LauncherNotice(text:model.notice) }
                        // Below Cancel: collapsed to one line by default.
                        if model.screen == .launching && model.graphics.phase != nil { GraphicsDetails(progress:model.graphics) }
                    }.frame(maxWidth:LauncherStyle.contentWidth).padding(.top,model.screen == .welcome ? 28 : 34)
                    Spacer(minLength:28)
                    VersionStatus(model:model).padding(.bottom,12)
                    HStack(spacing:12) {
                        FooterTile(title:"Settings",symbol:"gearshape") { model.sheet = .settings }.disabled(model.screen == .moveApp)
                        FooterTile(title:"Help & FAQ",symbol:"questionmark.circle") { model.makeReport();model.sheet = .help }
                        FooterTile(title:"About",symbol:"info.circle") { model.sheet = .about }
                    }.frame(maxWidth:LauncherStyle.contentWidth).padding(.bottom,24)
                }.padding(.horizontal,36).frame(maxWidth:.infinity).frame(minHeight:geometry.size.height)
            }.scrollIndicators(.hidden)
        }
        .background { LauncherBackground() }
        .font(LauncherStyle.font(14)).tint(.primary)
        .animation(reduceMotion ? nil : .easeInOut(duration:0.20),value:model.screen)
        .sheet(item:$model.sheet) { sheet in
            switch sheet {
            case .settings: SettingsSheet(model:model)
            case .help: HelpSheet(model:model)
            case .about: AboutSheet(model:model)
            case .uninstall: UninstallSheet(model:model).interactiveDismissDisabled(model.uninstall == .working)
            case .update: UpdateSheet(model:model).interactiveDismissDisabled(model.update == .installing)
                .onDisappear { model.updateSheetClosed() }
            case .whatsNew: WhatsNewSheet()
            }
        }
        .task { model.startup() }
    }
    private var subtitle:String {
        switch model.screen {
        case .welcome: return "Set up Steam, then install Counter-Strike 2 or Deadlock."
        case .moveApp:
            if let copy=model.installedCopy { return "Version \(copy.version) is in your Applications folder. Open it from there; this disk image is ejected for you." }
            return "\(Brand.name) runs from your Applications folder. It copies itself there, ejects this disk image and opens again."
        case .checking: return "Checking your installation and available storage."
        case .readyToInstall: return model.clientInstalled ? "Finish preparing your installation. Your game files and sign-in will be kept." : "Install the game components and Steam. It takes a few minutes."
        case .preparing: return model.stage.isEmpty ? "Preparing your game environment." : model.stage
        case .launching: return model.stage == "Opening Steam" ? "Waiting for its window to appear." : model.stage
        case .installer: return "Steam’s installer is finishing. Choose Continue when it’s done."
        case .running: return "Choose Play to return to your game, or Open Steam for your Library."
        case .ready: return model.gameInstalled ? "Choose a game. Steam opens and starts it for you." : "Open Steam, sign in, then install Counter-Strike 2 or Deadlock from your Library."
        case .driveMissing: return "Your games are installed on “\(model.driveName)”. Connect the drive and this app picks up where it left off."
        case .failure: return model.failure.message
        }
    }
    @ViewBuilder private var details:some View {
        switch model.screen {
        case .welcome:
            LauncherPanel {
                VStack(alignment:.leading,spacing:12) {
                    Text("Requirements").font(LauncherStyle.font(14,.semibold))
                    VStack(alignment:.leading,spacing:8) {
                        requirement("Mac", "Apple Silicon · macOS 26.5 or later")
                        requirement("Memory", "16 GB recommended")
                        requirement("Storage", "About 70 GB free per game, on this Mac or an external SSD")
                        requirement("Also", "Steam account, internet and Rosetta")
                    }
                    Divider()
                    VStack(alignment:.leading,spacing:5) {
                        Text("Recommended · tested setup").font(LauncherStyle.font(13,.semibold))
                        Text("Tested on an M2 Max. Other Apple Silicon Macs may perform differently.")
                            .font(LauncherStyle.font(13)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    }
                }
            }
        case .moveApp:
            if model.busy {
                HStack(spacing:12) {
                    ProgressView().controlSize(.small).accessibilityLabel("Moving")
                    Text(model.stage).foregroundStyle(.secondary)
                }
            } else if model.installedCopy == nil && !model.moveReplaces.isEmpty {
                LauncherNotice(text:"This replaces \(model.moveReplaces.joined(separator:" and ")), which moves to the Trash. Your games, settings and Steam sign-in are kept.")
            }
        case .checking:
            ProgressView().controlSize(.small).accessibilityLabel("Checking your Mac")
        case .preparing:
            HStack(spacing:12) {
                ProgressView().controlSize(.small).accessibilityLabel("Setup in progress")
                if model.downloadedBytes>0 {
                    Text(ByteCountFormatter.string(fromByteCount:Int64(model.downloadedBytes),countStyle:.file)+" downloaded")
                        .monospacedDigit().foregroundStyle(.secondary)
                }
            }
        case .launching:
            TimelineView(.periodic(from:model.launchStarted,by:1)) { context in
                let seconds=max(0,Int(context.date.timeIntervalSince(model.launchStarted)))
                VStack(spacing:20) {
                    HStack(spacing:12) {
                        ProgressView().controlSize(.small).accessibilityLabel("Opening Steam")
                        Text("\(seconds / 60):\(String(format:"%02d",seconds % 60)) elapsed")
                            .font(LauncherStyle.font(14,.medium)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    if seconds >= 30 {
                        Text("Taking longer than usual. Check the Dock for a Steam window.")
                            .font(LauncherStyle.font(13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    PerformanceTip()
                    if !model.firstMatchTipDismissed { FirstMatchTip { model.firstMatchTipDismissed=true } }
                }
            }
        case .readyToInstall:
            VStack(spacing:16) {
                if model.canChangeLocation { locationPanel }
                if model.lowStorage { storageWarning }
                else if !model.gameInstalled && !model.canChangeLocation { Text("A new installation needs about 70 GB of free space per game.").foregroundStyle(.secondary).font(LauncherStyle.font(13)) }
                if model.lowMemory && !model.gameInstalled { memoryWarning }
            }
        case .installer:
            // Steam opened outside this app lacks its renderer settings, so its
            // window can load blank until reopened here.
            LauncherNotice(text:"If a Steam window opened during setup, close it. Then choose Continue here. This app reopens Steam with the right display settings, and you can sign in there.")
        case .failure:
            if model.failure.code == "rosetta_required" {
                Text("macOS will guide you through Apple’s installation.").font(LauncherStyle.font(13)).foregroundStyle(.secondary)
            }
        case .ready, .running:
            VStack(spacing:16) {
                GamePicker(model:model)
                if model.lowStorage { storageWarning }
                PerformanceTip()
                if !model.firstMatchTipDismissed { FirstMatchTip { model.firstMatchTipDismissed=true } }
            }
        case .driveMissing: EmptyView()
        }
    }
    // Already filled in with the internal default: an optional change, not a
    // required decision. "Choose Another Location…" opens a folder picker.
    private enum LocationChoice: Hashable { case standard, current, other }
    private var locationPanel:some View {
        let choice=Binding<LocationChoice>(
            get: { InstallLocation.isStandard(model.root) ? .standard : .current },
            set: { value in
                switch value {
                case .standard: model.useLocation(InstallLocation.standard)
                case .other: DispatchQueue.main.async { model.chooseOtherLocation() }
                case .current: break
                }
            })
        return LauncherPanel {
            VStack(alignment:.leading,spacing:8) {
                HStack(spacing:12) {
                    Text("Install location").font(LauncherStyle.font(13)).foregroundStyle(.secondary)
                    Spacer(minLength:8)
                    Picker("Install location",selection:choice) {
                        Label(InstallLocation.title(InstallLocation.standard),systemImage:"internaldrive").tag(LocationChoice.standard)
                        if !InstallLocation.isStandard(model.root) {
                            Label(InstallLocation.title(model.root),systemImage:InstallLocation.isInternal(model.root) ? "folder" : "externaldrive").tag(LocationChoice.current)
                        }
                        Divider()
                        Text("Choose Another Location…").tag(LocationChoice.other)
                    }.labelsHidden().pickerStyle(.menu).fixedSize().disabled(model.busy)
                        .help(model.root.path)
                }
                Text("Needs about 70 GB per game · \(ByteCountFormatter.string(fromByteCount:Int64(model.freeBytes),countStyle:.file)) available")
                    .font(LauncherStyle.font(13)).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }
    private var storageWarning:some View {
        let free=ByteCountFormatter.string(fromByteCount:Int64(model.freeBytes),countStyle:.file)
        let drive=InstallLocation.isStandard(model.root) ? "Your Mac has" : "“\(model.driveName)” has"
        let fix=InstallLocation.isInternal(model.root) ? "Free up space in System Settings › General › Storage" : "Free up space on the drive"
        return LauncherNotice(text:"\(drive) \(free) free. We recommend about 70 GB for each game and their updates. You can continue, but the download may stop if storage runs out. \(fix)\(model.canChangeLocation ? ", or choose another install location." : ".")",symbol:"exclamationmark.triangle")
    }
    private var memoryWarning:some View {
        LauncherNotice(text:"Your Mac has \(model.memoryBytes>>30) GB of memory. We recommend 16 GB. You can continue, but games may load slowly or stutter. Quitting other apps before you play helps.",symbol:"exclamationmark.triangle")
    }
    private func requirement(_ title:String,_ value:String)->some View {
        HStack(alignment:.top,spacing:12) {
            Text(title).foregroundStyle(.secondary).frame(width:60,alignment:.leading)
            Text(value).frame(maxWidth:.infinity,alignment:.leading)
        }.font(LauncherStyle.font(13)).fixedSize(horizontal:false,vertical:true)
    }
    @ViewBuilder private var actions:some View {
        switch model.screen {
        case .welcome:
            LauncherPrimaryAction(title:"Get Started",action:model.check).keyboardShortcut(.defaultAction).disabled(model.busy)
        case .moveApp:
            if model.installedCopy != nil {
                LauncherPrimaryAction(title:"Open \(Brand.name)",action:model.openInstalledCopy).keyboardShortcut(.defaultAction).disabled(model.busy)
            } else {
                LauncherPrimaryAction(title:"Move to Applications",action:model.moveToApplications).keyboardShortcut(.defaultAction).disabled(model.busy)
            }
            Button("Quit") { model.quit() }.buttonStyle(.borderless).disabled(model.busy)
        case .readyToInstall:
            LauncherPrimaryAction(title:model.clientInstalled ? "Finish Setup" : "Install Steam",action:model.setup).keyboardShortcut(.defaultAction).disabled(model.busy)
        case .checking: EmptyView()
        case .preparing:
            if model.canCancel { Button("Pause Setup",action:model.cancel).buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.large).keyboardShortcut(.cancelAction) }
        case .launching:
            LauncherCancelAction(title:"Cancel",action:model.cancelLaunch).keyboardShortcut(.cancelAction).disabled(!model.canCancel)
        case .installer:
            LauncherPrimaryAction(title:"Continue",action:model.finishInstaller).keyboardShortcut(.defaultAction).disabled(model.busy)
        case .ready, .running:
            if model.installedGames.contains(model.selectedGame) {
                LauncherPrimaryAction(title:"Play \(model.selectedGame.title)",action:model.play).keyboardShortcut(.defaultAction).disabled(model.busy)
                // Steam on its own: the store, library, friends, settings.
                ClientAction(title:"Open Steam",secondary:true,action:model.launch).disabled(model.busy)
            } else {
                ClientAction(title:"Open Steam",action:model.launch).keyboardShortcut(.defaultAction).disabled(model.busy)
            }
        case .driveMissing:
            LauncherPrimaryAction(title:"Try Again",action:model.recheck).keyboardShortcut(.defaultAction).disabled(model.busy)
            Button("Set Up on This Mac Instead",action:model.useThisMac).buttonStyle(.borderless).disabled(model.busy)
        case .failure:
            if model.failure.code == "rosetta_required" {
                LauncherPrimaryAction(title:"Install Rosetta",action:model.installRosetta).keyboardShortcut(.defaultAction).disabled(model.busy)
                Button("Check Again",action:retry).buttonStyle(.borderless).disabled(model.busy)
            } else {
                LauncherPrimaryAction(title:model.failure.code == "cancelled" ? "Resume Setup" : "Try Again",action:retry).keyboardShortcut(.defaultAction).disabled(model.busy)
            }
        }
    }
    private func retry() {
        if model.failure.code == "close_installer_client" { model.finishInstaller() }
        else if ["run_from_installed_app","app_move_failed","app_name_taken"].contains(model.failure.code) { model.moveToApplications() }
        else if model.failure.code == "install_location_unavailable" { model.recheck() }
        else if model.clientInstalled && model.state["prepared_runtime"] as? String != model.release?.runtimeVersion { model.setup() }
        else if model.clientInstalled { model.launch() }
        else if model.state["active_runtime"] != nil { model.setup() }
        else { model.check() }
    }
}

// The installed version and update status, above the footer. Quiet when up to
// date; an available update is one click away.
struct VersionStatus: View {
    @Bindable var model:AppModel
    var body:some View {
        HStack(spacing:6) {
            Text("Version \(UpdateCheck.installed)")
            if !Brand.allowsUpdates { Text("·");Text("GPTK4 evaluation") }
            switch model.update {
            case .available(let item):
                Text("·")
                Button { model.sheet = .update } label: {
                    Label { Text("Update to \(item.version)").fontWeight(.semibold) } icon: { Image(systemName:"arrow.down.circle.fill").foregroundStyle(LauncherStyle.accent) }
                }.buttonStyle(.borderless).foregroundStyle(.primary).help("See what’s new and install the update")
            case .downloading, .installing:
                Text("·")
                Button("Updating…") { model.sheet = .update }.buttonStyle(.borderless)
            case .upToDate:
                Text("·");Text("Up to date")
            default: EmptyView()
            }
            if Brand.allowsUpdates {
                Text("·")
                Button("What’s New") { model.sheet = .whatsNew }.buttonStyle(.borderless)
            }
        }.font(LauncherStyle.font(12)).foregroundStyle(.secondary)
    }
}
// Every launch: other apps compete with the game for the GPU, CPU and memory; players
// who kept theirs open reported stutters.
struct PerformanceTip: View {
    var body:some View {
        Label("For the best performance, close other apps while you play.",systemImage:"bolt")
            .font(LauncherStyle.font(13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            .fixedSize(horizontal:false,vertical:true)
    }
}
// Shown until dismissed on the Play, opening and running screens: first matches
// compile the game's shaders on this Mac.
struct FirstMatchTip: View {
    let dismiss:()->Void
    var body:some View {
        HStack(alignment:.top,spacing:10) {
            Label {
                Text("Your first matches can stutter briefly while your Mac prepares the game’s graphics. It smooths out as you play, and the prepared graphics are kept for next time.")
                    .lineSpacing(3).fixedSize(horizontal:false,vertical:true)
            } icon: { Image(systemName:"sparkles") }
            Spacer(minLength:0)
            Button(action:dismiss) { Image(systemName:"xmark").font(.system(size:11,weight:.bold)).frame(width:22,height:22).contentShape(Rectangle()) }
                .buttonStyle(.borderless).foregroundStyle(.secondary).help("Dismiss this tip").accessibilityLabel("Dismiss tip")
        }.font(LauncherStyle.font(13)).foregroundStyle(.secondary)
            .padding(16).frame(maxWidth:.infinity,alignment:.leading)
            .background(LauncherStyle.accent.opacity(0.09),in:RoundedRectangle(cornerRadius:10,style:.continuous))
    }
}
// The Play screen's choice of game, remembered (AppModel.selectedGame). Each tile says
// whether Steam has installed it; one that isn't says how to get it.
struct GamePicker: View {
    @Bindable var model:AppModel
    @Environment(\.colorScheme) private var scheme
    private let tick=Timer.publish(every:15,on:.main,in:.common).autoconnect()
    var body:some View {
        VStack(spacing:12) {
            HStack(spacing:10) {
                ForEach(AppModel.Game.allCases) { game in
                    VStack(alignment:.leading,spacing:8) {
                        tile(game)
                        LaunchResolutionPicker(gameName:game.title,resolution:model.resolution(for:game),main:MainDisplay.current,
                                               disabled:model.busy || model.running == .game) { model.chooseResolution($0,for:game) }
                            .font(LauncherStyle.font(12)).padding(.leading,4)
                        Toggle("Fullscreen",isOn:Binding(get:{ model.fullscreen(game) },set:{ model.setFullscreen(game,$0) }))
                            .toggleStyle(.switch).controlSize(.small).font(LauncherStyle.font(12)).padding(.leading,4)
                            .disabled(model.busy || model.running == .game).accessibilityLabel("\(game.title) fullscreen")
                    }
                }
            }
            Text("Launch options also apply when you press Play in Steam.")
                .font(LauncherStyle.font(12)).foregroundStyle(.secondary)
            if !model.installedGames.contains(model.selectedGame) {
                LauncherNotice(text:"\(model.selectedGame.title) isn’t installed yet. Open Steam, find it in your Library (or the Store) and click Install. It appears here once it’s installed.",symbol:"arrow.down.circle")
            }
        }.onReceive(tick) { _ in model.refreshGames() }
    }
    private func tile(_ game:AppModel.Game) -> some View {
        let selected=model.selectedGame == game, installed=model.installedGames.contains(game)
        let shape=RoundedRectangle(cornerRadius:10,style:.continuous)
        return Button { model.selectedGame=game } label: {
            VStack(alignment:.leading,spacing:4) {
                Text(game.title).font(LauncherStyle.font(14,.semibold)).foregroundStyle(.primary).lineLimit(1)
                Label(installed ? "Installed" : "Not installed",systemImage:installed ? "checkmark.circle.fill" : "circle.dashed")
                    .font(LauncherStyle.font(12)).foregroundStyle(.secondary)
            }.padding(14).frame(maxWidth:.infinity,alignment:.leading)
                .background(LauncherStyle.surface(scheme),in:shape)
                .overlay { shape.strokeBorder(selected ? AnyShapeStyle(LauncherStyle.accent) : AnyShapeStyle(.primary.opacity(0.08)),lineWidth:selected ? 2 : 1) }
                .contentShape(shape)
        }.buttonStyle(.plain).disabled(model.busy)
            .accessibilityLabel("\(game.title), \(installed ? "installed" : "not installed")").accessibilityAddTraits(selected ? .isSelected : [])
    }
}
// The footer's three destinations, sized as buttons.
struct FooterTile: View {
    let title:String
    let symbol:String
    let action:()->Void
    var body:some View {
        Button(action:action) {
            VStack(spacing:6) {
                Image(systemName:symbol).font(.system(size:18,weight:.medium)).accessibilityHidden(true)
                Text(title).font(LauncherStyle.font(12,.semibold))
            }.frame(maxWidth:.infinity,minHeight:58)
        }.buttonStyle(FooterTileStyle())
    }
}
private struct FooterTileStyle: ButtonStyle {
    func makeBody(configuration:Configuration)->some View { FooterTileBody(configuration:configuration) }
}
private struct FooterTileBody: View {
    let configuration:ButtonStyleConfiguration
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused
    @State private var hovering=false
    var body:some View {
        configuration.label.foregroundStyle(enabled ? Color.primary : Color.secondary)
            .background(LauncherStyle.surface(scheme).opacity(hovering ? 1 : 0.72),in:RoundedRectangle(cornerRadius:10,style:.continuous))
            .overlay { RoundedRectangle(cornerRadius:10,style:.continuous).strokeBorder(focused ? Color.primary.opacity(0.8) : Color.primary.opacity(hovering ? 0.16 : 0.08),lineWidth:focused ? 2 : 1) }
            .contentShape(RoundedRectangle(cornerRadius:10,style:.continuous))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .onHover { hovering=$0 }
    }
}
