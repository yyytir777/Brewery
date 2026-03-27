//
//  RowInfoView.swift
//  Brewery
//
//  Created by Wonjae Lim on 3/27/26.
//

import SwiftUI

func infoRow(key: String, value: String) -> some View {
    HStack {
        Text(key)
            .foregroundStyle(.secondary)
            .frame(width: 100, alignment: .leading)
            .textSelection(.enabled)
        Spacer()
        Text(value)
            .multilineTextAlignment(.trailing)
            .textSelection(.enabled)
    }
    .padding(.vertical, 8)
    .padding(.horizontal, 4)
}

func infoLinkRow(key: String, url: String) -> some View {
    HStack {
        Text(key)
            .foregroundStyle(.secondary)
            .frame(width: 100, alignment: .leading)
            .textSelection(.enabled)
        Spacer()
        Link(url, destination: URL(string: url)!)
            .onHover { hovering in
                hovering ? NSCursor.pointingHand.push() : NSCursor.pop()
            }
            .lineLimit(1)
            .truncationMode(.tail)
            .textSelection(.enabled)
    }
    .padding(.vertical, 8)
    .padding(.horizontal, 4)
}
