//
//  RowInfoView.swift
//  Brewery
//
//  Created by Wonjae Lim on 3/27/26.
//

import SwiftUI

func validatedHTTPURL(from value: String) -> URL? {
    guard let url = URL(string: value),
          let scheme = url.scheme?.lowercased(),
          ["http", "https"].contains(scheme) else {
        return nil
    }
    return url
}

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
        if let destination = validatedHTTPURL(from: url) {
            Link(url, destination: destination)
                .onHover { hovering in
                    hovering ? NSCursor.pointingHand.push() : NSCursor.pop()
                }
                .lineLimit(1)
                .truncationMode(.tail)
                .textSelection(.enabled)
        } else {
            Text(url.isEmpty ? "unknown" : url)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
    .padding(.vertical, 8)
    .padding(.horizontal, 4)
}
