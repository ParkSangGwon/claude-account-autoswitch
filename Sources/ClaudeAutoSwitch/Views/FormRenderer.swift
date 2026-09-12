import SwiftUI
import AppKit
import AutoSwitchCore

/// Renders one `SettingField` from the catalog: label, help and the right control.
/// Commits go back as JSON (nil = back to the default).
struct FieldRow: View {
    @Environment(\.snapshotMode) private var snapshotMode
    let field: SettingField
    let value: JSON
    let onCommit: (JSON?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L(field.label)).font(.system(size: 13, weight: .semibold))
            // ImageRenderer draws AppKit-backed fields as placeholders; the PNGs show the value as text instead.
            if snapshotMode {
                Text(snapshotText).font(.system(size: 12, design: .monospaced)).foregroundStyle(.primary)
            } else {
                control.accessibilityLabel(L(field.label))
            }
            Text(L(field.help)).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 8)
    }

    private var snapshotText: String {
        switch field.kind {
        case .toggle: return value.bool == true ? L("on") : L("off")
        case .keyedNumbers: return value.isNull ? L("(default)") : value.pretty()
        default: return value.string ?? value.double.map { $0 == $0.rounded() ? String(Format.safeInt($0)) : String($0) } ?? L("(default)")
        }
    }

    @ViewBuilder
    private var control: some View {
        switch field.kind {
        case .toggle:
            Toggle(L(field.label), isOn: Binding(get: { value.bool ?? false }, set: { onCommit(.bool($0)) })).labelsHidden().toggleStyle(.switch).controlSize(.small)
        case .int(let min, let max, let step, let unit):
            NumberEditor(value: value.double, integer: true, min: min.map(Double.init), max: max.map(Double.init), step: Double(step), unit: unit, onCommit: { onCommit($0.map(JSON.number)) })
        case .double(let min, let max, let step, let unit):
            NumberEditor(value: value.double, integer: false, min: min, max: max, step: step, unit: unit, onCommit: { onCommit($0.map(JSON.number)) })
        case .text(let placeholder):
            TextEditorRow(value: value.string ?? "", placeholder: placeholder.map { L($0) } ?? "", onCommit: { onCommit($0.isEmpty ? nil : .string($0)) })
        case .picker(let options):
            Picker(L(field.label), selection: Binding(get: { value.string ?? options.first ?? "" }, set: { if $0 != value.string { onCommit(.string($0)) } })) {
                ForEach(options, id: \.self) { Text(L($0)).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 360)
        case .keyedNumbers(let keys):
            KeyedNumbersEditor(keys: keys, value: value, onCommit: onCommit)
        }
    }
}

struct NumberEditor: View {
    var value: Double?
    var integer: Bool
    var min: Double?
    var max: Double?
    var step: Double
    var unit: String?
    var onCommit: (Double?) -> Void
    @State private var text = ""
    @State private var error: String?

    var body: some View {
        HStack(spacing: 8) {
            TextField("", text: $text).textFieldStyle(.roundedBorder).frame(width: 110).multilineTextAlignment(.trailing)
                .onSubmit(commit)
            if let unit { Text(L(unit)).font(.system(size: 12)).foregroundStyle(.secondary) }
            Stepper("", onIncrement: { bump(step) }, onDecrement: { bump(-step) }).labelsHidden()
            if let error { Text(error).font(.system(size: 11)).foregroundStyle(.red) }
            Spacer()
        }
        .onAppear { text = format(value) }
        .onChange(of: value) { _, new in text = format(new) }
    }

    private func format(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "" }
        return integer || v == v.rounded() ? String(Format.safeInt(v)) : String(v)
    }

    private func bump(_ delta: Double) {
        let base = Double(text) ?? value ?? 0
        text = format(clamp(base + delta))
        commit()
    }

    private func clamp(_ v: Double) -> Double {
        var x = v
        if let min { x = Swift.max(min, x) }
        if let max { x = Swift.min(max, x) }
        return integer ? x.rounded() : x
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { error = nil; onCommit(nil); return }
        guard let v = Double(trimmed) else { error = L("not a number"); return }
        if let min, v < min { error = L("min %@", format(min)); return }
        if let max, v > max { error = L("max %@", format(max)); return }
        error = nil
        let clamped = integer ? v.rounded() : v
        if clamped != value { onCommit(clamped) }
    }
}

struct TextEditorRow: View {
    var value: String
    var placeholder: String
    var onCommit: (String) -> Void
    @State private var text = ""
    var body: some View {
        HStack {
            TextField(placeholder, text: $text).textFieldStyle(.roundedBorder).frame(maxWidth: 420)
                .onSubmit { if text != value { onCommit(text.trimmingCharacters(in: .whitespaces)) } }
            if text != value { Button(L("Apply")) { onCommit(text.trimmingCharacters(in: .whitespaces)) }.controlSize(.small) }
        }
        .onAppear { text = value }
        .onChange(of: value) { _, new in text = new }
    }
}

/// Per-window percentages; empty = default. Stored as fractions (0–1).
struct KeyedNumbersEditor: View {
    var keys: [String]
    var value: JSON
    var onCommit: (JSON?) -> Void
    @State private var texts: [String: String] = [:]
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let scalar = value.double {
                Text(L("Currently a single value: %@", Format.percent(scalar))).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ForEach(keys, id: \.self) { key in
                HStack {
                    Text(key).font(.system(size: 12, design: .monospaced)).frame(width: 150, alignment: .leading)
                    TextField(key, text: Binding(get: { texts[key] ?? "" }, set: { texts[key] = $0 }), prompt: Text(L("default")))
                        .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 80).multilineTextAlignment(.trailing)
                        .onSubmit(commit)
                    Text("%").foregroundStyle(.secondary)
                }
            }
            HStack {
                Button(L("Apply")) { commit() }.controlSize(.small)
                if let error { Text(error).font(.system(size: 11)).foregroundStyle(.red) }
            }
        }
        .onAppear(perform: load)
        .onChange(of: value) { _, _ in load() }
    }

    private func load() {
        var t: [String: String] = [:]
        if let obj = value.object {
            for (k, v) in obj { if let d = v.double { t[k] = String(format: "%g", d * 100) } }
        } else if let d = value.double {
            t["default"] = String(format: "%g", d * 100)
        }
        texts = t
        error = nil
    }

    /// Nothing is written while any entry is wrong: a silently dropped value would read as "applied".
    private func commit() {
        var obj: [String: JSON] = [:]
        for key in keys {
            let raw = (texts[key] ?? "").trimmingCharacters(in: .whitespaces)
            if raw.isEmpty { continue }
            guard let pct = Double(raw), pct >= 0, pct <= 100 else { error = "\(key): " + L("a number from 0 to 100"); return }
            obj[key] = .number(pct / 100)
        }
        error = nil
        onCommit(obj.isEmpty ? nil : .object(obj))
    }
}

/// A whole section rendered from the catalog.
struct SchemaPane: View {
    @Environment(AppStore.self) private var store
    let section: SettingsSection
    var fields: [SettingField] { SettingsCatalog.fields(in: section) }

    var body: some View {
        ForEach(fields) { field in
            FieldRow(field: field, value: store.configuration.flatMap { SettingsCatalog.value(field, in: $0) } ?? .null) { new in
                Task { await store.apply(field, value: new) }
            }
            Divider()
        }
    }
}
