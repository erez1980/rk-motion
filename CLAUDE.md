# RK Motion continuation

Read `docs/AUTOMATIC_STUDIO_PLAN.md` and `docs/AUTOMATIC_STUDIO_HANDOFF.md` before continuing the automatic studio work. The full original 10 + 20 product research is preserved in `docs/PRODUCT_AI_RESEARCH_2026-10-23.he.md`.

The owner wants all proposed capabilities to be automatic, one-tap actions. Do not make typing a prompt, choosing a song/person, trimming or configuring output a required step. Existing expert tools are optional. Keep analysis, indexes, preferences and rendering on iPhone; no silent server/PCC/Mac fallback. Do not call a partial implementation or a research dependency complete.

The Xcode project is generated: run `python3 scripts/generate-ios-project.py` after adding/removing Swift files. Run `python3 scripts/check-ios-store.py` after UI text changes. New UI strings need Hebrew and English catalog entries. Preserve the reliability fixes and shared preview/export timeline. Refer to the handoff for test commands and known limits. Do not alter unrelated user changes or publish/merge a release as part of a continuation without the user's instructions.
