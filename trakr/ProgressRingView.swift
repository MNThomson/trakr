import SwiftUI

struct ProgressRingView: View {
    let progress: Double  // 0.0 to 1.0
    let activeTime: String
    let startTime: String
    let finishTime: String
    let idleTime: String

    private var ringColor: LinearGradient {
        LinearGradient(
            colors: progressColors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var progressColors: [Color] {
        if progress >= 1.0 {
            return [Color(nsColor: .systemGreen), Color(nsColor: .systemTeal)]
        } else if progress >= 0.75 {
            return [Color(nsColor: .systemBlue), Color(nsColor: .systemGreen)]
        } else if progress >= 0.5 {
            return [Color(nsColor: .systemIndigo), Color(nsColor: .systemBlue)]
        } else {
            return [Color(nsColor: .systemOrange), Color(nsColor: .systemPink)]
        }
    }

    private var isComplete: Bool {
        progress >= 1.0
    }

    var body: some View {
        HStack(spacing: 16) {
            // Progress Ring
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 6)

                Circle()
                    .trim(from: 0, to: min(progress, 1.0))
                    .stroke(
                        ringColor,
                        style: StrokeStyle(lineWidth: 6, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.3), value: progress)
                    .shadow(
                        color: isComplete ? Color(nsColor: .systemGreen).opacity(0.6) : .clear,
                        radius: 4)

                Text(activeTime)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(.primary)
            }
            .frame(width: 56, height: 56)

            // Time Info
            VStack(alignment: .leading, spacing: 6) {
                timeRow(icon: "sunrise.fill", label: startTime, color: .orange)
                timeRow(icon: "flag.checkered", label: finishTime, color: .green)
                timeRow(icon: "cup.and.saucer.fill", label: idleTime, color: .secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func timeRow(icon: String, label: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(color)
                .frame(width: 16)

            Text(label)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(.primary)
        }
    }
}
