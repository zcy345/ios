import SwiftUI
import UIKit

/// 编辑游戏按键的布局：画面压暗、铺一层点阵，拖动摆放（靠近别的按钮或者画面中线时吸过去，画出对齐线，轻振一下），
/// 双指捏合调大小，点一下改设置。改的是一份副本，点“完成”才保存。
struct GameEditor: View {
    let app: AppModel
    let original: GameLayout
    let os: OsKind
    let done: () -> Void

    @State private var layout: GameLayout
    @State private var history: [GameLayout] = []
    @State private var selected: UUID?
    @State private var editing: UUID?
    @State private var dragStart: (UUID, CGPoint)?
    @State private var guides: (x: CGFloat?, y: CGFloat?) = (nil, nil)
    @State private var pinchBase: Double?
    @State private var adding = false
    @State private var picking = false
    @State private var layoutSettings = false
    @State private var confirmDiscard = false
    @State private var toolbarOffset: CGSize = .zero
    @State private var toolbarDrag: CGSize = .zero

    init(app: AppModel, original: GameLayout, os: OsKind, done: @escaping () -> Void) {
        self.app = app
        self.original = original
        self.os = os
        self.done = done
        _layout = State(initialValue: original)
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                Color.black.opacity(0.55).ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { selected = nil }
                dots(size)
                guideLines(size)
                ForEach(layout.items) { item in
                    itemView(item, size)
                }
                toolbar
                    .offset(x: toolbarOffset.width + toolbarDrag.width, y: toolbarOffset.height + toolbarDrag.height)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 8)
                if layout.items.isEmpty {
                    Text(L.t("game_empty_layout_hint")).font(.callout).foregroundStyle(Theme.sub)
                }
            }
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { v in
                        guard let id = selected, let i = index(id) else { return }
                        if pinchBase == nil {
                            pinchBase = layout.items[i].size
                            snapshot()
                        }
                        layout.items[i].size = min(max(pinchBase! * v.magnification, 36), 240)
                    }
                    .onEnded { _ in pinchBase = nil }
            )
        }
        .preferredColorScheme(.dark)
        .sheet(item: Binding(get: { editing.map { EditingID(id: $0) } }, set: { editing = $0?.id })) { e in
            if let i = index(e.id) {
                ItemSettings(item: Binding(get: { layout.items[min(i, layout.items.count - 1)] }, set: { v in
                    if let j = index(e.id) { layout.items[j] = v }
                }), os: os, duplicate: { duplicate(e.id) }, delete: { delete(e.id) }, willChange: snapshot)
                .presentationDetents([.medium, .large])
            }
        }
        .sheet(isPresented: $layoutSettings) {
            LayoutSettings(layout: $layout, willChange: snapshot).presentationDetents([.medium])
        }
        .sheet(isPresented: $picking) {
            KeyPicker(initial: [], os: os) { keys in
                snapshot()
                let item = GameTemplates.button(0.5, 0.5, 60, keys)
                layout.items.append(item)
                selected = item.id
            }
        }
        .confirmationDialog(L.t("game_add"), isPresented: $adding, titleVisibility: .visible) {
            Button(L.t("game_key")) { picking = true }
            Button(L.t("game_stick")) {
                snapshot()
                let s = GameTemplates.stick(0.2, 0.68, GameItem.wasd, sprint: "ShiftLeft")
                layout.items.append(s)
                selected = s.id
            }
        }
        .confirmationDialog(L.t("game_discard_title"), isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button(L.t("game_discard"), role: .destructive) { done() }
        } message: { Text(L.t("game_discard_text")) }
    }

    private struct EditingID: Identifiable { let id: UUID }

    private func index(_ id: UUID) -> Int? { layout.items.firstIndex { $0.id == id } }

    private func snapshot() {
        history.append(layout)
        if history.count > 100 { history.removeFirst() }
    }

    // ── 画布 ──

    private func dots(_ size: CGSize) -> some View {
        Canvas { ctx, s in
            let step: CGFloat = 24
            var y: CGFloat = step / 2
            while y < s.height {
                var x: CGFloat = step / 2
                while x < s.width {
                    ctx.fill(Path(ellipseIn: CGRect(x: x - 1, y: y - 1, width: 2, height: 2)), with: .color(.white.opacity(0.14)))
                    x += step
                }
                y += step
            }
        }
        .allowsHitTesting(false)
    }

    private func guideLines(_ size: CGSize) -> some View {
        ZStack {
            if let x = guides.x {
                Rectangle().fill(Theme.c3).frame(width: 1, height: size.height).position(x: x, y: size.height / 2)
            }
            if let y = guides.y {
                Rectangle().fill(Theme.c3).frame(width: size.width, height: 1).position(x: size.width / 2, y: y)
            }
        }
        .allowsHitTesting(false)
    }

    private func itemView(_ item: GameItem, _ size: CGSize) -> some View {
        let isSel = selected == item.id
        let d = item.size
        return ZStack {
            Circle().fill(item.kind == .stick ? Color.white.opacity(0.10) : Color.black.opacity(0.55))
            Circle().stroke(isSel ? Theme.c3 : Color.white.opacity(0.45), lineWidth: isSel ? 3 : 1.5)
            if item.kind == .stick {
                Circle().fill(Color.white.opacity(0.7)).frame(width: d * 0.4, height: d * 0.4)
            }
            Text(item.title(os: os)).font(.system(size: max(10, min(17, d * 0.24)), weight: .bold)).foregroundStyle(.white)
                .minimumScaleFactor(0.5).lineLimit(1).padding(6)
                .offset(y: item.kind == .stick ? d * 0.34 : 0)
        }
        .frame(width: d, height: d)
        .opacity(layout.opacity < 0.3 ? 0.6 : max(layout.opacity, 0.75))
        .position(x: item.x * size.width, y: item.y * size.height)
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { v in drag(item.id, v, size) }
                .onEnded { _ in
                    dragStart = nil
                    guides = (nil, nil)
                }
        )
        .onTapGesture {
            selected = item.id
            editing = item.id
        }
    }

    private func drag(_ id: UUID, _ v: DragGesture.Value, _ size: CGSize) {
        guard let i = index(id) else { return }
        if dragStart?.0 != id {
            snapshot()
            dragStart = (id, CGPoint(x: layout.items[i].x, y: layout.items[i].y))
            selected = id
        }
        guard let start = dragStart?.1 else { return }
        var x = start.x * size.width + v.translation.width
        var y = start.y * size.height + v.translation.height
        // 吸附：画面中线、别的按钮的中心
        var gx: CGFloat?, gy: CGFloat?
        let snap: CGFloat = 8
        let xs = [size.width / 2] + layout.items.filter { $0.id != id }.map { $0.x * size.width }
        let ys = [size.height / 2] + layout.items.filter { $0.id != id }.map { $0.y * size.height }
        if let s = xs.min(by: { abs($0 - x) < abs($1 - x) }), abs(s - x) < snap { x = s; gx = s }
        if let s = ys.min(by: { abs($0 - y) < abs($1 - y) }), abs(s - y) < snap { y = s; gy = s }
        if (gx != nil && guides.x == nil) || (gy != nil && guides.y == nil) {
            UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.6)
        }
        guides = (gx, gy)
        layout.items[i].x = Double(min(max(x / size.width, 0.02), 0.98))
        layout.items[i].y = Double(min(max(y / size.height, 0.02), 0.98))
    }

    // ── 工具栏 ──

    private var toolbar: some View {
        HStack(spacing: 4) {
            Image(systemName: "line.3.horizontal").foregroundStyle(Theme.faint).frame(width: 30, height: 40)
                .contentShape(Rectangle())
                .gesture(DragGesture().onChanged { toolbarDrag = $0.translation }.onEnded { v in
                    toolbarOffset.width += v.translation.width
                    toolbarOffset.height += v.translation.height
                    toolbarDrag = .zero
                })
            tool("arrow.uturn.backward", L.t("undo"), enabled: !history.isEmpty) {
                if let last = history.popLast() { layout = last }
            }
            tool("plus", L.t("game_add")) { adding = true }
            tool("slider.horizontal.3", L.t("game_layout_settings")) { layoutSettings = true }
            Divider().frame(height: 24).overlay(Theme.stroke)
            Button(L.t("cancel")) {
                if layout != original { confirmDiscard = true } else { done() }
            }
            .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.sub).padding(.horizontal, 8)
            Button(L.t("done")) {
                app.games.update(layout)
                done()
            }
            .font(.subheadline.weight(.bold)).foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Theme.gradient, in: Capsule())
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(alignment: .bottom) {
            Text(L.t("game_edit_hint")).font(.caption2).foregroundStyle(Theme.sub).offset(y: 22)
        }
    }

    private func tool(_ icon: String, _ label: String, enabled: Bool = true, _ f: @escaping () -> Void) -> some View {
        Button(action: f) {
            Image(systemName: icon).font(.system(size: 16, weight: .semibold)).foregroundStyle(enabled ? .white : Theme.faint)
                .frame(width: 40, height: 40)
        }
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    private func duplicate(_ id: UUID) {
        guard let i = index(id) else { return }
        snapshot()
        var c = layout.items[i]
        c.id = UUID()
        c.x = min(c.x + 0.06, 0.95)
        c.y = min(c.y + 0.06, 0.95)
        layout.items.append(c)
        selected = c.id
        editing = nil
    }

    private func delete(_ id: UUID) {
        snapshot()
        layout.items.removeAll { $0.id == id }
        selected = nil
        editing = nil
    }
}

/// 一个按钮 / 摇杆的设置
struct ItemSettings: View {
    @Binding var item: GameItem
    let os: OsKind
    let duplicate: () -> Void
    let delete: () -> Void
    let willChange: () -> Void
    @State private var picking = false

    private let sprintKeys = ["", "ShiftLeft", "ControlLeft", "AltLeft", "Space"]

    var body: some View {
        NavigationStack {
            Form {
                if item.kind == .button {
                    Section {
                        HStack {
                            Text(L.t("game_sends"))
                            Spacer()
                            Text(item.keys.map { GameItem.keyLabel($0, os: os) }.joined(separator: " + ")).foregroundStyle(Theme.sub)
                            Button(L.t("game_change")) { picking = true }
                        }
                        TextField(L.t("game_label"), text: Binding(get: { item.label }, set: { item.label = String($0.prefix(6)) }),
                                  prompt: Text(L.t("game_label_hint")))
                        Picker(L.t("game_mode"), selection: change(\.toggle)) {
                            Text(L.t("game_mode_hold")).tag(false)
                            Text(L.t("game_mode_toggle")).tag(true)
                        }
                        Toggle(isOn: change(\.look)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L.t("game_look"))
                                Text(L.t("game_look_desc")).font(.caption).foregroundStyle(Theme.sub)
                            }
                        }
                    }
                } else {
                    Section {
                        Picker(L.t("game_stick_keys"), selection: change(\.keys)) {
                            Text("W A S D").tag(GameItem.wasd)
                            Text("↑ ← ↓ →").tag(GameItem.arrows)
                        }
                        Picker(L.t("game_sprint"), selection: Binding(get: { item.sprint ?? "" }, set: { v in
                            willChange()
                            item.sprint = v.isEmpty ? nil : v
                        })) {
                            ForEach(sprintKeys, id: \.self) { k in
                                Text(k.isEmpty ? L.t("game_sprint_none") : KeyMap.label(k, os: os)).tag(k)
                            }
                        }
                        Toggle(isOn: change(\.floating)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L.t("game_floating"))
                                Text(L.t("game_floating_desc")).font(.caption).foregroundStyle(Theme.sub)
                            }
                        }
                    }
                }
                Section(L.t("game_size")) {
                    Slider(value: $item.size, in: 36...240, step: 2) { editing in if editing { willChange() } }
                }
                Section {
                    Button { duplicate() } label: { Label(L.t("game_duplicate_item"), systemImage: "plus.square.on.square") }
                    Button(role: .destructive) { delete() } label: { Label(L.t("delete"), systemImage: "trash") }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle(item.kind == .stick ? L.t("game_stick") : L.t("game_key"))
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $picking) {
            KeyPicker(initial: item.keys, os: os) { keys in
                willChange()
                item.keys = keys
            }
        }
    }

    private func change<T>(_ kp: WritableKeyPath<GameItem, T>) -> Binding<T> {
        Binding(get: { item[keyPath: kp] }, set: { v in
            willChange()
            item[keyPath: kp] = v
        })
    }
}

/// 方案设置：名称、不透明度、转视角灵敏度、按下时振动
struct LayoutSettings: View {
    @Binding var layout: GameLayout
    let willChange: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                TextField(L.t("game_layout_name"), text: $layout.name)
                VStack(alignment: .leading) {
                    Text(L.t("game_opacity"))
                    Slider(value: $layout.opacity, in: 0.15...1) { e in if e { willChange() } }
                }
                VStack(alignment: .leading) {
                    Text(L.t("game_look_speed") + String(format: " · %.1f×", layout.lookSpeed))
                    Slider(value: $layout.lookSpeed, in: 0.3...3, step: 0.1) { e in if e { willChange() } }
                }
                Toggle(L.t("game_haptics"), isOn: $layout.haptics)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle(L.t("game_layout_settings"))
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.dark)
    }
}

/// 选按键：鼠标、常用、字母、数字、功能键、方向和编辑、符号；按顺序点最多 3 个就是组合键
struct KeyPicker: View {
    let initial: [String]
    let os: OsKind
    let picked: ([String]) -> Void
    @State private var keys: [String]
    @Environment(\.dismiss) private var dismiss

    init(initial: [String], os: OsKind, picked: @escaping ([String]) -> Void) {
        self.initial = initial
        self.os = os
        self.picked = picked
        _keys = State(initialValue: initial)
    }

    private let groups: [(String, [String])] = [
        ("game_group_mouse", ["mouse:left", "mouse:right", "mouse:middle", "mouse:back", "mouse:forward", "wheel:up", "wheel:down"]),
        ("game_group_common", ["Space", "Enter", "Escape", "Tab", "ShiftLeft", "ControlLeft", "AltLeft", "MetaLeft", "Backspace", "CapsLock"]),
        ("game_group_letters", (65...90).map { "Key" + String(UnicodeScalar(UInt8($0))) }),
        ("game_group_digits", (0...9).map { "Digit\($0)" }),
        ("game_group_function", (1...12).map { "F\($0)" }),
        ("game_group_nav", ["ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight", "Home", "End", "PageUp", "PageDown", "Insert", "Delete"]),
        ("game_group_symbols", ["Backquote", "Minus", "Equal", "BracketLeft", "BracketRight", "Backslash", "Semicolon", "Quote", "Comma", "Period", "Slash"]),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(L.t("game_pick_combo")).font(.footnote).foregroundStyle(Theme.sub)
                    ForEach(groups, id: \.0) { title, list in
                        VStack(alignment: .leading, spacing: 8) {
                            SectionTitle(text: L.t(title))
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 58), spacing: 8)], spacing: 8) {
                                ForEach(list, id: \.self) { k in chip(k) }
                            }
                        }
                    }
                }
                .padding(18)
            }
            .background(Theme.bg)
            .navigationTitle(keys.isEmpty ? L.t("game_pick_title") : keys.map { GameItem.keyLabel($0, os: os) }.joined(separator: " + "))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L.t("cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L.t("ok")) {
                        picked(keys)
                        dismiss()
                    }
                    .disabled(keys.isEmpty)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func chip(_ k: String) -> some View {
        let i = keys.firstIndex(of: k)
        return Button {
            if let i { keys.remove(at: i) } else if keys.count < 3 { keys.append(k) }
        } label: {
            ZStack(alignment: .topTrailing) {
                Text(GameItem.keyLabel(k, os: os)).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .frame(maxWidth: .infinity, minHeight: 42)
                    .background(i != nil ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Theme.card), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.stroke))
                if let i {
                    Text("\(i + 1)").font(.caption2.weight(.bold)).foregroundStyle(Theme.bg).frame(width: 16, height: 16)
                        .background(Circle().fill(.white)).offset(x: 4, y: -4)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
