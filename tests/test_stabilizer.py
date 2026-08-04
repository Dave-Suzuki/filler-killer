"""PartialStabilizer: the commit-on-stability rule that keeps live counting
working when the recognizer never delivers a final result (field-reported on
newer macOS on-device recognition). Mirrors the Swift PartialStabilizerTests."""

from fillerkiller.realtime.stabilizer import PartialStabilizer


def test_commits_after_threshold_not_before():
    s = PartialStabilizer(commit_after=1.75)
    s.observe("um so basically", now=100.0)
    assert s.take_stable(101.0) is None
    assert s.take_stable(101.74) is None
    assert s.take_stable(101.75) == "um so basically"


def test_amended_text_restarts_the_clock():
    s = PartialStabilizer(commit_after=1.75)
    s.observe("um so", now=100.0)
    s.observe("um so basically we", now=101.5)
    assert s.take_stable(102.0) is None
    assert s.take_stable(103.25) == "um so basically we"


def test_repeated_identical_partials_do_not_restart_the_clock():
    s = PartialStabilizer(commit_after=1.75)
    s.observe("you know", now=100.0)
    s.observe("you know", now=101.0)
    s.observe("you know", now=101.5)
    assert s.take_stable(101.75) == "you know"


def test_take_is_consuming():
    s = PartialStabilizer(commit_after=1.0)
    s.observe("kind of done", now=100.0)
    assert s.take_stable(102.0) == "kind of done"
    assert s.take_stable(110.0) is None


def test_blank_partials_never_commit():
    s = PartialStabilizer(commit_after=1.0)
    s.observe("", now=100.0)
    assert s.take_stable(105.0) is None
    s.observe("   \n", now=106.0)
    assert s.take_stable(120.0) is None


def test_reset_clears():
    s = PartialStabilizer(commit_after=1.0)
    s.observe("i mean", now=100.0)
    s.reset()
    assert s.take_stable(105.0) is None
