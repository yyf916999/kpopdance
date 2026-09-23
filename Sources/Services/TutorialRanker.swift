import Foundation

/// Turns raw YouTube search results into a ranked "which tutorial should I actually learn from"
/// list.
///
/// Plain YouTube relevance optimises for clicks. A learner wants something different: a mirrored,
/// slowed, step-by-step breakdown of the *right song*, long enough to cover the whole routine, from
/// someone who teaches rather than performs. Every term below exists because it separates those
/// two populations.
struct TutorialRanker {
    var choreography: Choreography
    var channelBoosts: [String]
    var preferMirrored: Bool
    var languageHint: String

    func rank(hits: [YouTubeAPI.SearchHit],
              details: [String: YouTubeAPI.VideoDetail],
              excludeTerms: [String]) -> [TutorialVideo] {

        let now = Date()
        var results: [TutorialVideo] = []

        for hit in hits {
            let detail = details[hit.videoID]
            let haystack = "\(hit.title) \(hit.description)".lowercased()
            let titleLower = hit.title.lowercased()

            // Hard drops. A reaction video or a fancam is never the answer, no matter how popular.
            if excludeTerms.contains(where: { titleLower.contains($0) }) { continue }

            // The search query includes the song, but YouTube happily returns "top 10 hardest
            // choreos" style videos. Require the song or the artist to actually appear.
            let mentionsSong = titleLower.contains(choreography.title.lowercased())
            let mentionsArtist = titleLower.contains(choreography.artist.lowercased())
            if !mentionsSong && !mentionsArtist { continue }

            let duration = detail?.durationSeconds ?? 0
            let views = detail?.viewCount ?? 0
            let likes = detail?.likeCount ?? 0
            let embeddable = detail?.isEmbeddable ?? true
            let tags = (detail?.tags ?? []).map { $0.lowercased() }
            let searchText = haystack + " " + tags.joined(separator: " ")

            var score = 0.0

            // Teaching intent. "Tutorial" in the title is the single strongest signal.
            if titleLower.contains("tutorial") { score += 30 }
            if searchText.containsAny(["how to dance", "dance tutorial", "안무 배우기", "튜토리얼"]) { score += 12 }
            if searchText.containsAny(["step by step", "breakdown", "explained", "explanation", "slow"]) { score += 10 }

            // Mirrored is the difference between learning in an hour and learning in three.
            let mirrored = searchText.containsAny(["mirror", "mirrored", "거울", "거울모드", "reversed view"])
            if mirrored { score += preferMirrored ? 22 : 8 }

            let slowed = searchText.containsAny(["slow", "slowed", "느리게", "0.5x", "half speed"])
            if slowed { score += 8 }

            if searchText.containsAny(["count", "8 count", "eight count", "counts", "카운트"]) { score += 6 }

            // Both matching beats one matching — this filters out same-artist different-song hits.
            if mentionsSong && mentionsArtist { score += 15 }
            else if mentionsSong { score += 8 }

            // Popularity, log-scaled so a 40M-view video does not bury a 400k-view one that is
            // actually a better lesson.
            score += min(20, log10(Double(max(views, 1))) * 3.2)

            // Engagement beats raw reach for instructional content.
            if views > 2_000 {
                let ratio = Double(likes) / Double(views)
                score += min(12, ratio * 400)
            }

            // Duration shape. Real tutorials run 4-25 minutes.
            switch duration {
            case 0:
                score -= 2                      // unknown; mildly distrust
            case 1..<70:
                score -= 25                     // a Short: a teaser, not a lesson
            case 70..<210:
                score -= 6
            case 210...1_500:
                score += 10
            case 1_501...2_400:
                score += 3
            default:
                score -= 5
            }

            if channelBoosts.contains(where: { hit.channelTitle.caseInsensitiveCompare($0) == .orderedSame }) {
                score += 14
            }

            // Mild recency tilt: choreo tutorials get remade, and newer ones tend to match the
            // version people are currently dancing.
            let ageYears = now.timeIntervalSince(hit.publishedAt) / (365 * 24 * 3600)
            score += max(-6, 4 - ageYears * 1.2)

            // Language fit, inferred from the metadata we have.
            let isKorean = hit.title.containsHangul || (detail?.defaultAudioLanguage?.hasPrefix("ko") ?? false)
            if languageHint.hasPrefix("ko") && isKorean { score += 6 }
            if languageHint.hasPrefix("en") && !isKorean { score += 3 }

            // Unplayable in-app: keep it (the user can still open it on YouTube) but sink it.
            if !embeddable { score -= 40 }

            var badges: [TutorialBadge] = []
            if mirrored { badges.append(.mirrored) }
            if slowed { badges.append(.slowed) }
            if searchText.containsAny(["step by step", "breakdown", "part 1", "explained"]) { badges.append(.stepByStep) }
            if searchText.containsAny(["count", "counts", "카운트"]) { badges.append(.counts) }
            if duration >= 240 { badges.append(.fullRoutine) }
            if (1..<70).contains(duration) { badges.append(.shortForm) }
            badges.append(isKorean ? .korean : .english)

            results.append(TutorialVideo(
                id: hit.videoID,
                title: hit.title,
                channelTitle: hit.channelTitle,
                channelID: hit.channelID,
                description: String(hit.description.prefix(400)),
                publishedAt: hit.publishedAt,
                durationSeconds: duration,
                viewCount: views,
                likeCount: likes,
                thumbnailURL: hit.thumbnailURL,
                badges: badges,
                score: score,
                isEmbeddable: embeddable
            ))
        }

        // One lesson per teacher. Three uploads from the same channel at the top of the list is
        // less useful than three different teaching styles.
        var seenChannels: Set<String> = []
        var deduped: [TutorialVideo] = []
        var overflow: [TutorialVideo] = []
        for video in results.sorted(by: { $0.score > $1.score }) {
            if seenChannels.insert(video.channelID).inserted {
                deduped.append(video)
            } else {
                overflow.append(video)
            }
        }
        return deduped + overflow
    }

    /// Picks the single best "official reference" result: the dance practice / performance video
    /// the whole detail screen is built around.
    static func pickReference(hits: [YouTubeAPI.SearchHit],
                              details: [String: YouTubeAPI.VideoDetail],
                              seed: VideoSearchSeed,
                              choreography: Choreography) -> YouTubeAPI.SearchHit? {
        var best: (hit: YouTubeAPI.SearchHit, score: Double)?

        for hit in hits {
            let titleLower = hit.title.lowercased()
            if seed.excludeTerms.contains(where: { titleLower.contains($0) }) { continue }

            let detail = details[hit.videoID]
            guard detail?.isEmbeddable ?? true else { continue }

            var score = 0.0

            // Official channel is worth more than everything else combined: it is the difference
            // between the real choreography and someone's cover.
            if seed.channelHints.contains(where: { hit.channelTitle.localizedCaseInsensitiveContains($0) }) {
                score += 60
            }
            if titleLower.contains("dance practice") { score += 25 }
            if titleLower.contains("performance video") || titleLower.contains("choreography") { score += 12 }
            if titleLower.contains(choreography.title.lowercased()) { score += 20 }
            if titleLower.contains(choreography.artist.lowercased()) { score += 15 }
            if titleLower.containsAny(["fix ver", "fixed cam", "moving ver"]) { score += 5 }

            let views = detail?.viewCount ?? 0
            score += min(18, log10(Double(max(views, 1))) * 3.0)

            // Official practice videos run roughly a song length. Anything under a minute is a
            // teaser; anything over eight is a compilation.
            let duration = detail?.durationSeconds ?? 0
            if (100...500).contains(duration) { score += 12 }
            else if (1..<100).contains(duration) { score -= 20 }
            else if duration > 700 { score -= 12 }

            if best == nil || score > best!.score {
                best = (hit, score)
            }
        }
        return best?.hit
    }
}

// MARK: - Small text helpers

private extension String {
    func containsAny(_ needles: [String]) -> Bool {
        let lower = lowercased()
        return needles.contains { lower.contains($0) }
    }

    var containsHangul: Bool {
        unicodeScalars.contains {
            (0xAC00...0xD7A3).contains(Int($0.value)) || (0x1100...0x11FF).contains(Int($0.value))
        }
    }
}
