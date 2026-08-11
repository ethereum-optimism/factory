import os
import unittest

import agent_approval_check as approval


HEAD = "a" * 40
OLD_HEAD = "b" * 40


def user(login, user_type="User"):
    return {"login": login, "type": user_type}


def review(login, state="APPROVED", review_id=1, user_type="User", commit_id=HEAD):
    return {
        "id": review_id,
        "state": state,
        "submitted_at": f"2026-01-01T00:00:{review_id:02d}Z",
        "user": user(login, user_type),
        "commit_id": commit_id,
    }


def comment(login, body, comment_id=1, user_type="User"):
    return {
        "id": comment_id,
        "body": body,
        "user": user(login, user_type),
    }


def commit(email="human@example.com"):
    return {
        "sha": "c" * 40,
        "commit": {
            "author": {"email": email},
            "committer": {"email": email},
        },
    }


def config(required=2, excluded=(), branch_prefixes=()):
    return approval.Config(
        required_approvals=required,
        agent_emails=frozenset({"noreply@anthropic.com"}),
        agent_logins=frozenset({"claude[bot]", "claude-code[bot]"}),
        excluded_approvers=frozenset(value.lower() for value in excluded),
        protected_bases=("main",),
        agent_branch_prefixes=tuple(branch_prefixes),
    )


class FakeAPI:
    repository = "example/repo"

    def __init__(self):
        self.pr = {
            "number": 7,
            "state": "open",
            "user": user("human"),
            "head": {"sha": HEAD},
            "base": {"ref": "main"},
        }
        self.commits = [commit()]
        self.commits_incomplete = False
        self.reviews = []
        self.comments = []
        self.associated = [self.pr]
        self.siblings_incomplete = False
        self.permissions = set()
        self.statuses = []
        self.comment_bodies = []
        self.current_head = HEAD

    def get(self, path):
        if path == "/repos/example/repo":
            return {"default_branch": "main"}
        if path == "/repos/example/repo/pulls/7":
            result = dict(self.pr)
            result["head"] = {"sha": self.current_head}
            return result
        raise AssertionError(f"unexpected GET {path}")

    def paginate(self, path, maximum):
        if "/pulls/7/commits?" in path:
            return self.commits, self.commits_incomplete
        if "/pulls/7/reviews?" in path:
            return self.reviews, False
        if "/issues/7/comments?" in path:
            return self.comments, False
        if f"/commits/{HEAD}/pulls?" in path:
            return self.associated, self.siblings_incomplete
        raise AssertionError(f"unexpected pagination path {path}")

    def has_write_permission(self, login):
        return login.lower() in self.permissions

    def post_status(self, sha, state, description):
        self.statuses.append((sha, state, description))

    def upsert_comment(self, comments, body):
        self.comment_bodies.append(body)


class HelpersTest(unittest.TestCase):
    def test_parse_approve_requires_exact_first_line(self):
        self.assertEqual(approval.parse_approve(f"/approve {HEAD[:12]}"), HEAD[:12])
        self.assertEqual(
            approval.parse_approve(f"  /approve {HEAD}\nquoted email"), HEAD
        )
        self.assertIsNone(approval.parse_approve(f"please /approve {HEAD}"))
        self.assertIsNone(approval.parse_approve("/approve abc"))
        self.assertIsNone(approval.parse_approve(f"/approve {HEAD} extra"))

    def test_latest_decisive_review_wins(self):
        reviews = [
            review("Alice", "APPROVED", 1),
            review("Alice", "COMMENTED", 2),
            review("Alice", "CHANGES_REQUESTED", 3),
        ]
        latest = approval.latest_reviews(reviews)
        self.assertEqual(latest["alice"]["state"], "CHANGES_REQUESTED")

    def test_agent_detection_checks_author_and_committer(self):
        pr = {"user": user("human")}
        found, reason = approval.detect_agent_activity(
            pr, [commit("noreply@anthropic.com")], False, [], config()
        )
        self.assertTrue(found)
        self.assertIn("agent author email", reason)

    def test_agent_login_is_case_insensitive(self):
        pr = {"user": user("Claude[bot]", "Bot")}
        found, _ = approval.detect_agent_activity(pr, [commit()], False, [], config())
        self.assertTrue(found)

    def test_agent_branch_prefix_detected_regardless_of_identity(self):
        pr = {"user": user("bot-account"), "head": {"sha": HEAD, "ref": "agent/some-change"}}
        found, reason = approval.detect_agent_activity(
            pr, [commit("shared@example.com")], False, [], config(branch_prefixes=("agent/",))
        )
        self.assertTrue(found)
        self.assertIn("agent/", reason)

    def test_non_agent_branch_prefix_not_detected(self):
        pr = {"user": user("bot-account"), "head": {"sha": HEAD, "ref": "feature/other-change"}}
        found, _ = approval.detect_agent_activity(
            pr, [commit("human@example.com")], False, [], config(branch_prefixes=("agent/",))
        )
        self.assertFalse(found)

    def test_more_than_one_hundred_commits_fails_closed(self):
        pr = {"user": user("human")}
        found, reason = approval.detect_agent_activity(
            pr, [commit()], True, [], config()
        )
        self.assertTrue(found)
        self.assertIn("more than 100 commits", reason)

    def test_resolve_event(self):
        self.assertEqual(
            approval.resolve_pr_number(
                "pull_request_target", {"pull_request": {"number": 9}}
            ),
            9,
        )
        self.assertEqual(
            approval.resolve_pr_number(
                "pull_request_review", {"pull_request": {"number": 11}}
            ),
            11,
        )
        self.assertEqual(
            approval.resolve_pr_number(
                "issue_comment",
                {"issue": {"number": 8, "pull_request": {"url": "x"}}},
            ),
            8,
        )
        self.assertIsNone(
            approval.resolve_pr_number("issue_comment", {"issue": {"number": 8}})
        )

    def test_merge_group_head_sha_parsed(self):
        self.assertEqual(
            approval.merge_group_head_sha({"merge_group": {"head_sha": HEAD}}), HEAD
        )
        self.assertEqual(approval.merge_group_head_sha({}), "")

    def test_evaluate_merge_group_posts_success(self):
        api = FakeAPI()
        approval.evaluate_merge_group(api, {"merge_group": {"head_sha": HEAD}})
        self.assertEqual(
            api.statuses[-1],
            (HEAD, "success", "Approved before entering the merge queue"),
        )

    def test_evaluate_merge_group_rejects_invalid_sha(self):
        api = FakeAPI()
        with self.assertRaises(approval.APIError):
            approval.evaluate_merge_group(api, {"merge_group": {"head_sha": "nope"}})
        self.assertEqual(api.statuses, [])

    def test_pagination_link_parser(self):
        header = (
            '<https://api.github.com/resource?page=2>; rel="next", '
            '<https://api.github.com/resource?page=4>; rel="last"'
        )
        self.assertEqual(
            approval.next_link(header), "https://api.github.com/resource?page=2"
        )

    def test_attacker_cannot_claim_sticky_comment_marker(self):
        api = object.__new__(approval.GitHubAPI)
        api.repository = "example/repo"
        calls = []
        api.request = lambda method, path, payload: calls.append((method, path, payload))
        os.environ["AGENT_APPROVAL_PR_NUMBER"] = "7"
        attacker_comment = comment("attacker", approval.COMMENT_MARKER)
        api.upsert_comment([attacker_comment], "trusted body")
        self.assertEqual(calls[0][0], "POST")
        self.assertEqual(calls[0][1], "/repos/example/repo/issues/7/comments")


class ProcessTest(unittest.TestCase):
    def setUp(self):
        os.environ["AGENT_APPROVAL_PR_NUMBER"] = "7"

    def test_human_pull_request_passes_without_comment(self):
        api = FakeAPI()
        approval.process(api, config(), 7)
        self.assertEqual(
            api.statuses,
            [
                (HEAD, "pending", "Evaluation in progress"),
                (HEAD, "success", "No agent activity"),
            ],
        )
        self.assertEqual(api.comment_bodies, [])

    def test_agent_pull_request_stays_pending_without_approvals(self):
        api = FakeAPI()
        api.pr["user"] = user("claude[bot]", "Bot")
        approval.process(api, config(), 7)
        self.assertEqual(api.statuses[-1][1:], ("pending", "Need 2 approvals (have 0)"))
        self.assertIn("Human approvals: **0/2**", api.comment_bodies[-1])

    def test_two_distinct_write_capable_humans_pass(self):
        api = FakeAPI()
        api.pr["user"] = user("claude[bot]", "Bot")
        api.reviews = [
            review("alice"),
            review("OptimismBot", review_id=2),
            review("github-actions[bot]", review_id=3, user_type="Bot"),
            review("eve", review_id=4),
        ]
        api.comments = [comment("bob", f"/approve {HEAD}")]
        api.permissions = {"alice", "bob", "optimismbot"}
        approval.process(api, config(excluded=("OptimismBot",)), 7)
        self.assertEqual(api.statuses[-1][1:], ("success", "2/2 human approvals"))
        self.assertIn("@alice, @bob", api.comment_bodies[-1])
        self.assertNotIn("@optimismbot", api.comment_bodies[-1].lower())
        self.assertNotIn("@eve", api.comment_bodies[-1])

    def test_review_and_comment_from_same_user_count_once(self):
        api = FakeAPI()
        api.pr["user"] = user("claude[bot]", "Bot")
        api.reviews = [review("alice")]
        api.comments = [comment("alice", f"/approve {HEAD}")]
        api.permissions = {"alice"}
        approval.process(api, config(), 7)
        self.assertEqual(api.statuses[-1][1:], ("pending", "Need 2 approvals (have 1)"))

    def test_stale_native_commit_id_approval_does_not_count(self):
        api = FakeAPI()
        api.pr["user"] = user("claude[bot]", "Bot")
        api.reviews = [
            review("alice", commit_id=OLD_HEAD),
            review("bob", review_id=2, commit_id=HEAD),
        ]
        api.permissions = {"alice", "bob"}
        approval.process(api, config(), 7)
        self.assertEqual(api.statuses[-1][1:], ("pending", "Need 2 approvals (have 1)"))
        self.assertIn("@bob", api.comment_bodies[-1])
        self.assertIn("Stale SHA-bound approvals", api.comment_bodies[-1])
        self.assertNotIn("Approvers: @alice", api.comment_bodies[-1])

    def test_old_sha_approval_is_stale(self):
        api = FakeAPI()
        api.pr["user"] = user("claude[bot]", "Bot")
        api.comments = [comment("alice", f"/approve {OLD_HEAD}")]
        api.permissions = {"alice"}
        approval.process(api, config(), 7)
        self.assertEqual(api.statuses[-1][1:], ("pending", "Need 2 approvals (have 0)"))
        self.assertIn("Stale SHA-bound approvals", api.comment_bodies[-1])

    def test_sibling_pull_request_holds_success_at_pending(self):
        api = FakeAPI()
        sibling = {
            "number": 8,
            "state": "open",
            "head": {"sha": HEAD},
            "base": {"ref": "main"},
        }
        api.associated.append(sibling)
        approval.process(api, config(), 7)
        self.assertEqual(
            api.statuses[-1][1:],
            ("pending", "Another protected PR shares this head"),
        )
        self.assertIn("#8", api.comment_bodies[-1])

    def test_history_overflow_leaves_initial_pending_status(self):
        api = FakeAPI()
        api.pr["user"] = user("claude[bot]", "Bot")

        original_paginate = api.paginate

        def overflow(path, maximum):
            if "/reviews?" in path:
                return [], True
            return original_paginate(path, maximum)

        api.paginate = overflow
        with self.assertRaises(approval.APIError):
            approval.process(api, config(), 7)
        self.assertEqual(api.statuses, [(HEAD, "pending", "Evaluation in progress")])

    def test_head_change_during_evaluation_never_posts_success(self):
        api = FakeAPI()
        api.pr["user"] = user("claude[bot]", "Bot")
        api.reviews = [review("alice"), review("bob", review_id=2)]
        api.permissions = {"alice", "bob"}
        calls = 0
        original_get = api.get

        def changing_get(path):
            nonlocal calls
            result = original_get(path)
            if path.endswith("/pulls/7"):
                calls += 1
                if calls > 1:
                    result["head"] = {"sha": OLD_HEAD}
            return result

        api.get = changing_get
        with self.assertRaises(approval.APIError):
            approval.process(api, config(), 7)
        self.assertEqual(api.statuses, [(HEAD, "pending", "Evaluation in progress")])

    def test_unprotected_base_posts_no_status(self):
        api = FakeAPI()
        api.pr["base"] = {"ref": "develop"}
        approval.process(api, config(), 7)
        self.assertEqual(api.statuses, [])


if __name__ == "__main__":
    unittest.main()
