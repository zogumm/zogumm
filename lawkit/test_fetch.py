"""
fetch.py 파서 테스트 — 네트워크 없이 돈다.

법제처 API 응답은 형태가 들쭉날쭉하다. 결과가 1건이면 dict, 여러 건이면 list 로
오고, target 에 따라 중첩 깊이와 필드명이 다르다 (법령명한글 / 자치법규명).
그 변형들을 픽스처로 고정해둔다.

실제 응답이 여기 픽스처와 다르면 fetch 가 실패한다. 그때는 받은 JSON 을
픽스처로 추가하고 파서를 고치면 된다 — 어디를 고쳐야 하는지가 명확해진다.

실행: python3 -m unittest test_fetch -v
"""

import unittest

from fetch import dig, as_list, parse_search, parse_byeolpyo, plan_attachment, BASE


class Dig(unittest.TestCase):
    def test_중첩된_키를_찾는다(self):
        self.assertEqual(dig({"a": {"b": {"c": 1}}}, "c"), 1)

    def test_리스트_안쪽도_훑는다(self):
        self.assertEqual(dig({"a": [{"b": 2}]}, "b"), 2)

    def test_없으면_None(self):
        self.assertIsNone(dig({"a": 1}, "z"))

    def test_as_list는_단일값도_감싼다(self):
        self.assertEqual(as_list({"x": 1}), [{"x": 1}])
        self.assertEqual(as_list([1, 2]), [1, 2])
        self.assertEqual(as_list(None), [])


class ParseSearch(unittest.TestCase):
    """법령 검색 응답"""

    def test_여러_건이면_정확히_일치하는_걸_고른다(self):
        # "건축법" 으로 검색하면 시행령·시행규칙이 같이 온다
        data = {"LawSearch": {"law": [
            {"법령명한글": "건축법 시행령", "법령일련번호": "111", "시행일자": "20260101"},
            {"법령명한글": "건축법", "법령일련번호": "222", "시행일자": "20250701"},
            {"법령명한글": "건축법 시행규칙", "법령일련번호": "333", "시행일자": "20260301"},
        ]}}
        meta, err = parse_search(data, "건축법", "law")

        self.assertIsNone(err)
        self.assertEqual(meta["법령명"], "건축법")
        self.assertEqual(meta["MST"], "222")
        self.assertEqual(meta["시행일자"], "20250701")

    def test_결과가_1건이면_dict_로_온다(self):
        data = {"LawSearch": {"law": {
            "법령명한글": "건축법", "법령일련번호": "222", "시행일자": "20250701",
        }}}
        meta, err = parse_search(data, "건축법", "law")

        self.assertIsNone(err)
        self.assertEqual(meta["MST"], "222")

    def test_정확히_일치하는_게_없으면_첫_건을_쓴다(self):
        data = {"LawSearch": {"law": [
            {"법령명한글": "건축법 시행령", "법령일련번호": "111"},
        ]}}
        meta, err = parse_search(data, "건축법시행령", "law")

        self.assertIsNone(err)
        self.assertEqual(meta["법령명"], "건축법 시행령")

    def test_자치법규는_필드명이_다르다(self):
        data = {"LawSearch": {"law": [{
            "자치법규명": "서울특별시 건축 조례",
            "자치법규일련번호": "999",
            "시행일자": "20260401",
        }]}}
        meta, err = parse_search(data, "서울특별시 건축 조례", "ordin")

        self.assertIsNone(err)
        self.assertEqual(meta["MST"], "999")
        self.assertEqual(meta["법령명"], "서울특별시 건축 조례")

    def test_결과가_비면_오류를_돌려준다(self):
        meta, err = parse_search({"LawSearch": {"totalCnt": "0"}}, "없는법", "law")
        self.assertIsNone(meta)
        self.assertIn("검색 결과 없음", err)

    def test_일련번호가_없으면_구조가_바뀐_것이므로_오류로_세운다(self):
        # 조용히 MST=None 으로 진행하면 다음 요청이 이상하게 실패한다
        data = {"LawSearch": {"law": [{"법령명한글": "건축법"}]}}
        meta, err = parse_search(data, "건축법", "law")

        self.assertIsNone(meta)
        self.assertIn("일련번호", err)


class ParseByeolpyo(unittest.TestCase):
    def test_별표_목록을_뽑는다(self):
        parsed = {"법령": {"별표": {"별표단위": [
            {"별표번호": "1", "별표제목": "용도별 건축물의 종류"},
            {"별표번호": "2", "별표제목": "건축물의 범위"},
        ]}}}
        self.assertEqual(len(parse_byeolpyo(parsed)), 2)

    def test_별표가_1건이면_dict(self):
        parsed = {"법령": {"별표": {"별표단위": {"별표번호": "1", "별표제목": "허용 건축물"}}}}
        got = parse_byeolpyo(parsed)
        self.assertEqual(len(got), 1)
        self.assertEqual(got[0]["별표번호"], "1")

    def test_별표가_없는_법령도_있다(self):
        self.assertEqual(parse_byeolpyo({"법령": {"조문": {}}}), [])


class PlanAttachment(unittest.TestCase):
    def test_상대경로_링크에_BASE를_붙인다(self):
        label, url, fname = plan_attachment({
            "별표번호": "1", "별표제목": "허용 건축물",
            "별표서식파일링크": "/LSW/flDownload.do?flSeq=123",
        })
        self.assertEqual(label, "별표1 허용 건축물")
        self.assertEqual(url, BASE + "/LSW/flDownload.do?flSeq=123")
        self.assertTrue(fname.endswith(".hwp"))

    def test_절대경로_링크는_그대로_쓴다(self):
        _, url, _ = plan_attachment({
            "별표번호": "1", "별표서식파일링크": "https://law.go.kr/x.hwp",
        })
        self.assertEqual(url, "https://law.go.kr/x.hwp")

    def test_PDF_링크는_확장자가_pdf(self):
        _, _, fname = plan_attachment({
            "별표번호": "2", "별표제목": "서식",
            "별표서식PDF파일링크": "/LSW/flDownloadPDF.do?flSeq=9",
        })
        self.assertTrue(fname.endswith(".pdf"))

    def test_HWP_링크가_있으면_그걸_우선한다(self):
        _, url, fname = plan_attachment({
            "별표번호": "1",
            "별표서식파일링크": "/a.hwp",
            "별표서식PDF파일링크": "/a.pdf",
        })
        self.assertTrue(url.endswith("/a.hwp"))
        self.assertTrue(fname.endswith(".hwp"))

    def test_링크가_없으면_url이_None(self):
        label, url, fname = plan_attachment({"별표번호": "1", "별표제목": "링크없음"})
        self.assertEqual(label, "별표1 링크없음")
        self.assertIsNone(url)
        self.assertIsNone(fname)

    def test_파일명에서_경로문자를_제거한다(self):
        _, _, fname = plan_attachment({
            "별표번호": "1", "별표제목": '주택/근생: 규모"제한"',
            "별표서식파일링크": "/a.hwp",
        })
        for bad in '\\/:*?"<>|':
            self.assertNotIn(bad, fname)

    def test_제목이_아주_길어도_파일명이_터지지_않는다(self):
        _, _, fname = plan_attachment({
            "별표번호": "1", "별표제목": "가" * 300,
            "별표서식파일링크": "/a.hwp",
        })
        self.assertLessEqual(len(fname), 84)  # 80자 + 확장자


if __name__ == "__main__":
    unittest.main()
