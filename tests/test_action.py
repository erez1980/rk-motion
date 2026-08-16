from sofit.action import _normalise, _ranges


def test_normalise_limits_an_outlier():
    got = _normalise({0: 0.0, 1: 1.0, 2: 2.0, 3: 100.0})
    assert got[0] == 0.0
    assert got[3] == 1.0
    assert 0 < got[2] <= 1


def test_ranges_merges_a_single_quiet_second_and_applies_padding():
    clips = _ranges({0: 0, 1: .8, 2: .9, 3: 0, 4: .8, 5: .9, 6: 0},
                    threshold=.55, min_duration=4, padding=2, total_duration=10)
    assert len(clips) == 1
    assert clips[0]["start"] == 0
    assert clips[0]["end"] == 8


def test_ranges_can_split_long_suggestions_to_a_user_limit():
    clips = _ranges({second: .9 for second in range(10)}, threshold=.55,
                    min_duration=2, padding=0, total_duration=10, max_duration=3)
    assert [clip["duration"] for clip in clips] == [3, 3, 3, 1]
