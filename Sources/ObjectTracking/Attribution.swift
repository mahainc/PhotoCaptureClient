// MARK: - Attribution

/// Provenance & licensing note for the `ObjectTracking` module.
///
/// This is a **clean-room Swift reimplementation** of standard track-by-detection algorithms, written
/// from their published papers and the permissively-licensed (MIT) original repositories — **not**
/// derived from `mikel-brostrom/boxmot` (a.k.a. `yolo_tracking`), which is **AGPL-3.0** and would impose
/// strong-copyleft obligations on a closed-source app.
///
/// Algorithms & sources:
/// - **SORT** — Bewley et al., 2016 (the constant-velocity Kalman + IoU association idea).
/// - **ByteTrack** — Zhang et al., ECCV 2022 — two-stage association (`ifzhang/ByteTrack`, MIT,
///   © 2021 Yifu Zhang).
/// - **OC-SORT** — Cao et al., CVPR 2023 — Observation-Centric Momentum / Re-Update / Recovery
///   (`noahcao/OC_SORT`, MIT).
/// - **BoT-SORT** — Aharon et al., 2022 — camera-motion compensation (`NirAharon/BoT-SORT`, MIT,
///   © 2022 Nir Aharon).
///
/// MIT requires retaining the upstream copyright/permission notices; this file serves that purpose.
public enum ObjectTrackingAttribution {
    public static let notice = """
        ObjectTracking — clean-room Swift reimplementation of SORT / ByteTrack / OC-SORT / BoT-SORT \
        from their papers and MIT-licensed reference repositories. Not derived from boxmot (AGPL-3.0). \
        ByteTrack © 2021 Yifu Zhang (MIT); OC-SORT (MIT); BoT-SORT © 2022 Nir Aharon (MIT).
        """
}
