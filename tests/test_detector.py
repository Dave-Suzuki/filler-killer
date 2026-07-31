from fillerkiller.detector import Utterance, analyze_text, analyze_utterances


def terms(text, **kw):
    return [h.term for h in analyze_text(text, **kw)]


class TestVocalized:
    def test_um_uh_detected(self):
        assert terms("Um, I think, uh, we should go.") == ["um", "uh"]

    def test_vocalized_excluded_for_posthoc(self):
        # Granola strips um/uh anyway; the flag keeps post-hoc stats honest.
        assert terms("Um, I think so.", include_vocalized=False) == []

    def test_no_substring_matches(self):
        assert terms("The umbrella and the error were ahead.") == []


class TestPhrases:
    def test_you_know(self):
        assert terms("It was, you know, pretty hard.") == ["you know"]

    def test_i_mean_and_kinda(self):
        assert terms("I mean, it's kinda rough.") == ["i mean", "kinda"]

    def test_kind_of_hedge(self):
        assert terms("It was kind of difficult.") == ["kind of"]

    def test_kind_of_classifier_not_counted(self):
        assert terms("What kind of car is that?") == []
        assert terms("It's the kind of thing we do.") == []

    def test_single_word_fillers(self):
        assert terms("Basically it was literally done.") == ["basically", "literally"]

    def test_case_insensitive(self):
        assert terms("You know, Actually, it worked.") == ["you know", "actually"]


class TestLike:
    def test_discourse_like_counted(self):
        assert terms("It was like really hard.") == ["like"]

    def test_would_like_not_counted(self):
        assert terms("I would like a coffee.") == []

    def test_looks_like_not_counted(self):
        assert terms("It looks like rain.") == []

    def test_like_to_not_counted(self):
        assert terms("I like to run.") == []

    def test_like_that_not_counted(self):
        assert terms("I like that idea.") == []

    def test_something_like_not_counted(self):
        assert terms("It costs something like $1,300.") == []


class TestSo:
    def test_sentence_initial_so_counted(self):
        assert terms("So we decided to ship it.") == ["so"]

    def test_mid_sentence_so_not_counted(self):
        assert terms("It was so good we stayed.") == []

    def test_so_after_period_counted(self):
        assert terms("We shipped. So the next step is QA.") == ["so"]

    def test_so_far_not_counted(self):
        assert terms("So far it works.") == []

    def test_so_after_comma_not_sentence_initial(self):
        assert terms("Yes, so basically done.") == ["basically"]


class TestRepetition:
    def test_exact_repeat(self):
        assert terms("I I think the the plan works.") == ["i i", "the the"]

    def test_prefix_repeat_contraction(self):
        assert terms("we we're very understanding") == ["we we're"]

    def test_allowed_doubles_not_counted(self):
        assert terms("It was very very good. No no, really.") == []

    def test_triple_repeat_counts_once_per_pair(self):
        # "so so so" -> pairs at (0,1); token 2 unpaired after consuming 0-1
        hits = analyze_text("that that that")
        assert [h.term for h in hits] == ["that that"]


class TestSpans:
    def test_char_spans_slice_back_to_source(self):
        text = "It was, you know, kind of hard."
        for h in analyze_text(text):
            assert text[h.start : h.end].lower() == h.term


class TestUtterances:
    def test_only_me_speaker_analyzed(self):
        utts = [
            Utterance("Me", "You know, I think so."),
            Utterance("Chelsea", "You know what I mean, basically."),
            Utterance("Me", "It was kind of hard."),
        ]
        result = analyze_utterances(utts)
        assert [h.term for h in result.hits] == ["you know", "kind of"]
        assert result.word_count == 10  # "You know I think so" + "It was kind of hard"

    def test_rate_per_100_words(self):
        filler_free = "the team shipped a strong release and customers responded well overall today, with more arriving for eager reviewers"
        utts = [Utterance("Me", "you know " + filler_free)]  # 18 distinct words, 1 hit
        result = analyze_utterances(utts)
        assert result.word_count == 20
        assert result.per_100_words == 5.0

    def test_empty(self):
        result = analyze_utterances([])
        assert result.filler_count == 0
        assert result.per_100_words == 0.0

    def test_counts_by_term_sorted_desc(self):
        utts = [Utterance("Me", "You know, it was like hard, you know.")]
        result = analyze_utterances(utts)
        assert result.counts_by_term() == {"you know": 2, "like": 1}

    def test_real_granola_style_excerpt(self):
        # Shape verified against a real Granola transcript: lexical fillers and
        # stutter repeats survive; um/uh never appear.
        text = (
            "And I know you you know, generally try to make sense better. "
            "The the reason is, like, as Chelsea touched upon, we keep having "
            "the consistent challenging feedback."
        )
        got = terms(text)
        assert "you you" in got
        assert "the the" in got
        assert "like" in got
