#!/usr/bin/env swift
import AppKit
import CoreGraphics
import Foundation

private let canvasSize: CGFloat = 1024

private struct IconAsset {
  let filename: String
  let pixels: Int
}

private let assets = [
  IconAsset(filename: "AppIcon-16.png", pixels: 16),
  IconAsset(filename: "AppIcon-16@2x.png", pixels: 32),
  IconAsset(filename: "AppIcon-32.png", pixels: 32),
  IconAsset(filename: "AppIcon-32@2x.png", pixels: 64),
  IconAsset(filename: "AppIcon-128.png", pixels: 128),
  IconAsset(filename: "AppIcon-128@2x.png", pixels: 256),
  IconAsset(filename: "AppIcon-256.png", pixels: 256),
  IconAsset(filename: "AppIcon-256@2x.png", pixels: 512),
  IconAsset(filename: "AppIcon-512.png", pixels: 512),
  IconAsset(filename: "AppIcon-512@2x.png", pixels: 1024),
]

private func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1)
  -> CGColor
{
  CGColor(
    colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
    components: [red, green, blue, alpha]
  )!
}

private func gradient(
  _ colors: [CGColor],
  locations: [CGFloat] = [0, 1]
) -> CGGradient {
  CGGradient(
    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
    colors: colors as CFArray,
    locations: locations
  )!
}

private func polygon(_ points: [CGPoint]) -> CGPath {
  let path = CGMutablePath()
  path.addLines(between: points)
  path.closeSubpath()
  return path
}

private func fill(
  _ path: CGPath,
  in context: CGContext,
  colors: [CGColor],
  start: CGPoint,
  end: CGPoint
) {
  context.saveGState()
  context.addPath(path)
  context.clip()
  context.drawLinearGradient(
    gradient(colors),
    start: start,
    end: end,
    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
  )
  context.restoreGState()
}

private func drawIcon(in context: CGContext) {
  // Apple's macOS icon grid: an 824-point tile centred on the 1024 canvas.
  let tile = CGPath(
    roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
    cornerWidth: 186,
    cornerHeight: 186,
    transform: nil
  )

  context.saveGState()
  context.setShadow(offset: CGSize(width: 0, height: -12), blur: 24, color: color(0, 0, 0, 0.45))
  context.addPath(tile)
  context.setFillColor(color(0.04, 0.04, 0.04))
  context.fillPath()
  context.restoreGState()

  context.saveGState()
  context.addPath(tile)
  context.clip()
  context.drawLinearGradient(
    gradient([color(0.13, 0.13, 0.135), color(0.055, 0.055, 0.06), color(0.02, 0.02, 0.02)],
      locations: [0, 0.5, 1]),
    start: CGPoint(x: 512, y: 924),
    end: CGPoint(x: 512, y: 100),
    options: []
  )
  context.drawRadialGradient(
    gradient([color(0.90, 0.63, 0.05, 0.14), color(0.90, 0.63, 0.05, 0)]),
    startCenter: CGPoint(x: 512, y: 512),
    startRadius: 0,
    endCenter: CGPoint(x: 512, y: 512),
    endRadius: 360,
    options: []
  )
  context.restoreGState()

  context.addPath(tile)
  context.setStrokeColor(color(1, 1, 1, 0.07))
  context.setLineWidth(4)
  context.strokePath()

  // "Ni", centred on the tile. A geometric N: two stems, with the diagonal
  // laid over them like a folded ribbon.
  let top: CGFloat = 736
  let bottom: CGFloat = 288
  let stem: CGFloat = 100
  let letterWidth: CGFloat = 340
  let letterGap: CGFloat = 58
  let left = 512 - (letterWidth + letterGap + stem) / 2
  let right = left + letterWidth
  let leftStem = CGRect(x: left, y: bottom, width: stem, height: top - bottom)
  let rightStem = CGRect(x: right - stem, y: bottom, width: stem, height: top - bottom)
  let diagonal = polygon([
    CGPoint(x: left, y: top),
    CGPoint(x: left + stem, y: top),
    CGPoint(x: right, y: bottom),
    CGPoint(x: right - stem, y: bottom),
  ])
  let stemGold = [color(0.86, 0.58, 0.03), color(0.70, 0.45, 0.02)]

  fill(
    CGPath(rect: leftStem, transform: nil), in: context, colors: stemGold,
    start: CGPoint(x: 0, y: top), end: CGPoint(x: 0, y: bottom))
  fill(
    CGPath(rect: rightStem, transform: nil), in: context, colors: stemGold,
    start: CGPoint(x: 0, y: top), end: CGPoint(x: 0, y: bottom))

  context.saveGState()
  context.setShadow(offset: CGSize(width: 0, height: 0), blur: 36, color: color(0, 0, 0, 0.55))
  context.addPath(diagonal)
  context.setFillColor(color(0.90, 0.63, 0.05))
  context.fillPath()
  context.restoreGState()

  let ribbonGold = [color(0.98, 0.76, 0.24), color(0.90, 0.63, 0.05)]
  fill(
    diagonal, in: context, colors: ribbonGold,
    start: CGPoint(x: left, y: top), end: CGPoint(x: right, y: bottom))

  // A lowercase i in the stems' gold, its dot in the ribbon's and level with
  // the top of the N.
  let iLeft = right + letterGap
  let dotGap: CGFloat = 46
  let dot = CGRect(x: iLeft, y: top - stem, width: stem, height: stem)
  let iStem = CGRect(x: iLeft, y: bottom, width: stem, height: dot.minY - dotGap - bottom)
  fill(
    CGPath(rect: iStem, transform: nil), in: context, colors: stemGold,
    start: CGPoint(x: 0, y: iStem.maxY), end: CGPoint(x: 0, y: bottom))
  fill(
    CGPath(rect: dot, transform: nil), in: context, colors: ribbonGold,
    start: CGPoint(x: dot.minX, y: dot.maxY), end: CGPoint(x: dot.maxX, y: dot.minY))
}

private func renderIcon(pixels: Int, destination: URL) throws {
  let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
  guard
    let context = CGContext(
      data: nil,
      width: pixels,
      height: pixels,
      bitsPerComponent: 8,
      bytesPerRow: pixels * 4,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
  else {
    throw CocoaError(.fileWriteUnknown)
  }

  let scale = CGFloat(pixels) / canvasSize
  context.scaleBy(x: scale, y: scale)
  drawIcon(in: context)

  guard let image = context.makeImage() else {
    throw CocoaError(.fileWriteUnknown)
  }
  let representation = NSBitmapImageRep(cgImage: image)
  guard let data = representation.representation(using: .png, properties: [:]) else {
    throw CocoaError(.fileWriteUnknown)
  }
  try data.write(to: destination, options: .atomic)
}

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let repositoryRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let outputDirectory =
  repositoryRoot
  .appendingPathComponent("App/Assets.xcassets/AppIcon.appiconset", isDirectory: true)

for asset in assets {
  try renderIcon(
    pixels: asset.pixels,
    destination: outputDirectory.appendingPathComponent(asset.filename)
  )
}

print("Generated \(assets.count) app icon assets in \(outputDirectory.path)")
