// Offline release notes, also available from Help.
enum WhatsNew {
    static let version="1.1"
    static let items:[(symbol:String, title:String, detail:String)]=[
        ("macwindow","Open Steam requests its window",
         "Restores Steam through its window request instead of only activating its process. The launcher no longer pulls focus back to your game afterward."),
        ("arrow.clockwise","Steam browser recovery",
         "Open Steam repairs an idle client after an update replaces its browser helper. Finish and close a running game before restarting Steam."),
        ("checkmark.circle","Wine session cleanup",
         "Temporary launch requests are reaped, and closing Steam waits for its remaining Wine services to exit."),
        ("rectangle.expand.vertical","Deadlock display issue remains under investigation",
         "UI and click positions may shift after changing video settings. Try closing Deadlock, turning off Fullscreen in MacVolvo and relaunching at a resolution that fits your display."),
    ]
}
