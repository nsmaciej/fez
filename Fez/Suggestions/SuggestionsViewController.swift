//
//  SuggestionsViewController.swift
//  Fez
//
//  Created by Maciej Goszczycki on 16/08/2017.
//  Copyright © 2017 Maciej. All rights reserved.
//

import Cocoa

private let cornerRadius: CGFloat = 5

// Thank you https://github.com/marcomasser/OverlayTest
private func maskImage(radius: CGFloat) -> NSImage {
    let edgeLength = 2 * radius + 1 // One pixel stripe that isn't an edge inset
    let maskSize = NSSize(width: edgeLength, height: edgeLength)
    let maskImage = NSImage(size: maskSize, flipped: false) { rect in
        NSColor.black.set()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        return true
    }
    maskImage.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
    maskImage.resizingMode = .stretch
    return maskImage
}

open class SuggestionsViewController: NSViewController {
    /// Bind this to an NSTableView in the storyboard
    @IBOutlet open weak var tableView: NSTableView!
    /// Text field which owns this view controller.
    /// Only set after is is returned by the delegate method
    public internal(set) weak var owningTextField: SuggestingTextField!
    
    private var localEventMonitor: Any?
    private var window: FadeInWindow?
    private var shownItems: [Suggestable] = []
    // TrackingRowView uses this to ignore mouseEnter
    private var lastIgnoreRequest: TimeInterval = 0
    // Ignore next 0.25s of mouse events (except moves)
    var shouldIgnoreMouseEnterEvent: Bool {
        let now = ProcessInfo().systemUptime
        return now - lastIgnoreRequest < 0.25
    }
    
    weak var selectedItem: Suggestable? {
        if tableView.selectedRow < 0 || !window!.isVisible { return nil }
        return shownItems[tableView.selectedRow]
    }

    open override func viewDidLoad() {
        super.viewDidLoad()
        tableView.dataSource = self
        tableView.delegate = self
    }
    
    private func ignoreMouse() {
        lastIgnoreRequest = ProcessInfo().systemUptime
    }
    
    // Do not call super in both. Just not implemented
    open override func moveDown(_ sender: Any?) {
        ignoreMouse()
        setSelectedRow(tableView.selectedRow + 1)
    }
    
    open override func moveUp(_ sender: Any?) {
        ignoreMouse()
        setSelectedRow(tableView.selectedRow - 1)
    }
    
    private func setSelectedRow(_ ix: Int) {
        if ix < 0 || ix >= tableView.numberOfRows { return }

        let clipView = tableView.enclosingScrollView!.contentView
        let rowRect = tableView.rect(ofRow: ix)
        if !clipView.documentVisibleRect.contains(rowRect) {
            if rowRect.minY > clipView.bounds.minY {
                // Top side of rowrect is below top of clip view, we are scrolling down
                // Make bottom side of rowrect bottom of clip view
                clipView.setBoundsOrigin(NSPoint(x: 0, y:
                    rowRect.maxY - clipView.bounds.height + cornerRadius))
            } else {
                clipView.setBoundsOrigin(NSPoint(x: 0, y:
                    rowRect.minY - cornerRadius))
            }
        }
    
        tableView.selectRowIndexes([ix], byExtendingSelection: false)
    }
    
    @objc private func tableClicked(_ sender: Any) {
        owningTextField.sendSelectedItem()
    }
    
    deinit {
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
            localEventMonitor = nil
        }
    }
}

// Window mgmt
extension SuggestionsViewController {
    func updateItems(_ items: [Suggestable]) {
        shownItems = items
        tableView?.reloadData() // Note question mark
    }
    
    func showItems(_ items: [Suggestable], animate: Bool) {
        updateItems(items)
        show(animate: animate)
        // Select first row when typing or first responder
        setSelectedRow(0)
        ignoreMouse()
        tableView.enclosingScrollView!.flashScrollers()
    }
    
    private func processEvent(_ event: NSEvent) {
        // We can click inside this window
        if event.window == window { return }
        
        if event.window == owningTextField.window {
            // Note: Hitting nil should also close window
            let hit = event.window?.hitTest(event)
            if hit != nil && (hit == owningTextField || hit == owningTextField.currentEditor()) {
                show(animate: true)
            } else {
                close()
            }
        } else {
            close()
        }
    }
    
    private func show(animate: Bool) {
        if window == nil {
            let window = FadeInWindow(contentRect: NSRect(x: 0, y: 0, width: 20, height: 20),
                                      styleMask: .borderless,
                                      backing: .buffered,
                                      defer: false) // Do not defer
            window.hasShadow = true
            window.backgroundColor = .clear
            window.isOpaque = false
            
            // Wrap us in an effect view
            let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: window.frame.size))
            effect.material = .menu
            effect.state = .active
            effect.maskImage = maskImage(radius: cornerRadius)
            effect.addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
            view.edges(to: effect)
            window.contentView = effect
            self.window = window
            
            // Table view is loaded now
            let scrollView = tableView.enclosingScrollView!
            scrollView.automaticallyAdjustsContentInsets = false
            scrollView.contentInsets = NSEdgeInsets(top: cornerRadius,
                                                    left: 0,
                                                    bottom: cornerRadius,
                                                    right: 0)
            // Not sure why this works the way it doesn. But negative bounds work.
            // But only if we re-layout first
            scrollView.layoutSubtreeIfNeeded()
            scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: -cornerRadius))
            scrollView.verticalScrollElasticity = .none
            scrollView.drawsBackground = false
            scrollView.borderType = .noBorder
            tableView.backgroundColor = .clear
            tableView.selectionHighlightStyle = .regular
            tableView.allowsTypeSelect = false
            tableView.allowsEmptySelection = false
            tableView.allowsMultipleSelection = false
            tableView.headerView = nil
            
            // Single clicks
            tableView.target = self
            tableView.action = #selector(tableClicked(_:))

            // Close when we select a different app
            NotificationCenter.default.addObserver(self,
                                                   selector: #selector(close),
                                                   name: NSWindow.didResignKeyNotification,
                                                   object: owningTextField.window!)
            // Close when we click outside
            let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            // Weak self important since deinit removes this
            localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
                self?.processEvent(event)
                return event
            }
        }
        
        // Change frame
        if tableView.numberOfRows == 0 {
            close()
            return
        }
        
        window!.setFrame(calculateFrame(), display: true)
        if !window!.isVisible {
            // For some stupid reason we need to do this here
            // Otherwise it does not register as a child
            // CustomMenus also does it in this order, but fails to mention why
            // Also orderOut removes the child so we don't care ourselves
            owningTextField.window!.addChildWindow(self.window!, ordered: .above)
            if animate {
                window!.orderFrontAnimating(sender: self)
            } else {
                window!.orderFront(self)
            }
            // Show first item when showing window for any reason
            ignoreMouse()
            setSelectedRow(0)
        }
    }
    
    private func calculateFrame() -> NSRect {
        // Important otherwise first time around we might get wrong sizes
        window!.layoutIfNeeded()
        
        let lastRow = min(tableView.numberOfRows - 1,
                          owningTextField.suggestionsLimit - 1)
        // No need to convert since in scroll view
        let lastRowRect = tableView.rect(ofRow: max(lastRow, 0))
        
        // Table view is flipped by default it seems
        // Do not forget about content insets for corners
        let rowBottom = lastRowRect.height + lastRowRect.minY + cornerRadius * 2
        let scrollRect = view.convert(tableView.enclosingScrollView!.frame,
                                      from: tableView.enclosingScrollView)
        let tableOffset = view.bounds.height - scrollRect.minY - scrollRect.height
        let height = tableOffset + rowBottom
        
        var frame = owningTextField.screenFrame
            .offsetBy(dx: 0, dy: -height - 3)
        frame.size.height = height
        return frame
    }
    
    // Called by SuggestingTextField also
    @objc func close() {
        window?.orderOut(self)
    }
}

extension SuggestionsViewController: NSTableViewDelegate {
    public func tableView(_ tableView: NSTableView,
                          viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        return owningTextField.suggestionDelegate?.viewFor(tableView, item: shownItems[row])
    }
    
    public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("TrackingRow")
        let reused = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableRowView
        
        if reused != nil { return reused }
        let fresh = TrackingRowView()
        fresh.owningSuggestionsController = self
        fresh.identifier = id
        return fresh
    }
}

extension SuggestionsViewController: NSTableViewDataSource {
    public func numberOfRows(in tableView: NSTableView) -> Int {
        return shownItems.count
    }
    
    public func tableView(_ tableView: NSTableView,
                          objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        return shownItems[row]
    }
}
