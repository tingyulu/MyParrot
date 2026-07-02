import SwiftUI

/// MyParrot mascot — a chibi parrot wearing headphones. While recording it
/// "sings": beak opens/closes, music notes float up, the head bobs, and
/// sound-wave rings pulse. Idle = still.
struct ParrotMascot: View {
    var size: CGFloat = 58
    var isRecording: Bool = false

    @State private var bob = false
    @State private var ring = false
    @State private var sing = false
    @State private var notes = false

    private var s: CGFloat { size }

    var body: some View {
        ZStack {
            if isRecording { rings }
            parrot
                .rotationEffect(.degrees(isRecording && bob ? 3 : -3))
                .offset(y: isRecording && bob ? -s * 0.03 : 0)
            if isRecording { musicNotes }
        }
        .frame(width: s, height: s)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) { bob = true }
            withAnimation(.easeOut(duration: 1.7).repeatForever(autoreverses: false)) { ring = true }
            withAnimation(.easeInOut(duration: 0.32).repeatForever(autoreverses: true)) { sing = true }
            withAnimation(.easeIn(duration: 1.25).repeatForever(autoreverses: false)) { notes = true }
        }
    }

    // Pulsing sound-wave rings while recording.
    private var rings: some View {
        ZStack {
            Circle().stroke(MP.blue, lineWidth: 2).frame(width: s * 0.7, height: s * 0.7)
                .scaleEffect(ring ? 1.5 : 0.5).opacity(ring ? 0 : 0.5)
            Circle().stroke(MP.coral, lineWidth: 2).frame(width: s * 0.7, height: s * 0.7)
                .scaleEffect(ring ? 1.35 : 0.5).opacity(ring ? 0 : 0.4)
        }
    }

    // ♪ ♫ rising from the beak and fading.
    private var musicNotes: some View {
        ZStack {
            Text("♪").font(.system(size: s * 0.22, weight: .bold)).foregroundStyle(MP.coral)
                .offset(x: s * 0.30, y: notes ? -s * 0.42 : -s * 0.02).opacity(notes ? 0 : 0.95)
            Text("♫").font(.system(size: s * 0.18, weight: .bold)).foregroundStyle(MP.blue)
                .offset(x: s * 0.42, y: notes ? -s * 0.52 : s * 0.02).opacity(notes ? 0 : 0.85)
        }
    }

    private var parrot: some View {
        ZStack {
            Ellipse().fill(MP.blue).frame(width: s * 0.58, height: s * 0.64).offset(y: s * 0.14)
            Ellipse().fill(Color(red: 0.71, green: 0.83, blue: 0.96))
                .frame(width: s * 0.32, height: s * 0.42).offset(y: s * 0.18)
            // crest
            Triangle().fill(Color(red: 0.937, green: 0.624, blue: 0.153))
                .frame(width: s * 0.12, height: s * 0.16).offset(x: -s * 0.05, y: -s * 0.40)
            Triangle().fill(Color(red: 0.729, green: 0.459, blue: 0.090))
                .frame(width: s * 0.12, height: s * 0.16).offset(x: s * 0.05, y: -s * 0.40)
            // head
            Circle().fill(MP.blue).frame(width: s * 0.56, height: s * 0.56).offset(y: -s * 0.16)
            // eyes
            eye(dx: -s * 0.12)
            eye(dx: s * 0.12)
            // beak: upper fixed, lower drops open while singing
            BeakTri().fill(MP.coral).frame(width: s * 0.16, height: s * 0.12).offset(y: -s * 0.05)
            BeakTri().fill(Color(red: 0.66, green: 0.27, blue: 0.13))
                .frame(width: s * 0.14, height: s * 0.10).rotationEffect(.degrees(180))
                .offset(y: (isRecording && sing) ? s * 0.06 : -s * 0.005)
            // headphones
            Band().stroke(headphone, style: StrokeStyle(lineWidth: s * 0.05, lineCap: .round))
                .frame(width: s * 0.62, height: s * 0.2).offset(y: -s * 0.30)
            earCup(dx: -s * 0.30)
            earCup(dx: s * 0.30)
        }
    }

    private var headphone: Color { Color(red: 0.17, green: 0.17, blue: 0.16) }

    private func eye(dx: CGFloat) -> some View {
        ZStack {
            Circle().fill(.white).frame(width: s * 0.14, height: s * 0.14)
            Circle().fill(Color(red: 0.016, green: 0.173, blue: 0.325)).frame(width: s * 0.07, height: s * 0.07)
        }.offset(x: dx, y: -s * 0.18)
    }

    private func earCup(dx: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: s * 0.04).fill(headphone)
            .frame(width: s * 0.1, height: s * 0.16).offset(x: dx, y: -s * 0.14)
    }
}

private struct Triangle: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

// Downward-pointing beak triangle.
private struct BeakTri: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

// Headphone band: an arch from bottom-left over the top to bottom-right.
private struct Band: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.maxY),
                       control: CGPoint(x: r.midX, y: r.minY - r.height * 0.4))
        return p
    }
}
