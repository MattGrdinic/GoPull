//
//  DeleteConfirmation.swift
//  GoPull
//
//  The sheet that stands between a selection and an empty card.
//
//  The camera has no trash. A deleted clip is gone, and if it was not imported
//  first it was the only copy. So this shows exactly what would go, names the
//  clips rather than counting them, and separates the ones with a copy on this
//  Mac from the ones without — that distinction is the whole difference between
//  tidying up and losing footage.
//

import Combine
import SwiftUI

struct DeleteConfirmationView: View {
    let plan: DeletionPlan
    let destination: URL
    let onDelete: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if !plan.unbacked.isEmpty { unbackedWarning }
                    if !plan.backed.isEmpty { backedSection }
                    if !plan.unbacked.isEmpty { unbackedSection }
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(width: 520, height: 460)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: plan.allBacked ? "trash" : "exclamationmark.triangle.fill")
                .font(.system(size: 22))
                .foregroundStyle(plan.allBacked ? Color.secondary : Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Delete \(plan.rows.count) item\(plan.rows.count == 1 ? "" : "s") from the camera?")
                    .font(.headline)
                Text("\(plan.files.count) file\(plan.files.count == 1 ? "" : "s") · \(plan.bytes.byteLabel) · this cannot be undone")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
    }

    private var unbackedWarning: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("\(plan.unbacked.count) of these have no copy on this Mac. Deleting them "
                 + "removes the only copy — the camera has no trash and nothing can be "
                 + "recovered afterwards.")
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
        .padding(10)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private var backedSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("\(plan.backed.count) already imported", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
            Text("Verified at full size in \(destination.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))")
                .font(.caption2).foregroundStyle(.tertiary)
                .lineLimit(1).truncationMode(.head)
            ForEach(plan.backed) { row in
                fileLine(row, safe: true)
            }
        }
    }

    private var unbackedSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("\(plan.unbacked.count) not on this Mac", systemImage: "xmark.circle.fill")
                .font(.caption).foregroundStyle(.orange)
            ForEach(plan.unbacked) { row in
                fileLine(row, safe: false)
            }
        }
    }

    private func fileLine(_ row: MediaRow, safe: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: safe ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(safe ? Color.green : Color.orange)
            Text(row.name).font(.callout)
            if row.hasRaw {
                Text("+ RAW").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Text(row.size(includingRaw: true).byteLabel)
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button(role: .destructive, action: onDelete) {
                Text(plan.allBacked
                     ? "Delete \(plan.rows.count) from Camera"
                     : "Delete Anyway")
            }
            // Deliberately not the default action: this should take a click,
            // not a stray Return.
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }
}
