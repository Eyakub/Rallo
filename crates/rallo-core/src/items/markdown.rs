//! The small Markdown grammar of a note's text (0023 §2). Nothing is stored:
//! the app styles the editor from `spans` and shows `plain_text` in previews,
//! both through the FFI so Swift never re-implements the grammar.
//!
//! Like `tags`, there is no parser crate: one pass over a `Vec<char>` per line,
//! with a UTF-16 offset table for the ranges handed to `NSTextView`.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Marker,
    Bold,
    Italic,
    Strike,
    Code,
    LinkText,
    LinkUrl,
    Heading(u8),
    Bullet,
    Number,
    TaskBox { checked: bool },
    TaskDone,
    ListContent,
    Quote,
    CodeBlock,
    CodeFence,
    Divider,
}

/// A styled range in UTF-16 units.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Span {
    pub kind: Kind,
    pub start: u32,
    pub len: u32,
}

/// `(kind, start, end)` in `char` indexes.
type Raw = (Kind, usize, usize);

struct Parser<'a> {
    c: &'a [char],
    out: Vec<Raw>,
}

/// An opening fence is 3+ backticks and an info string without a backtick
/// (so "```x``` y" is inline code); a closing one is 3+ backticks and spaces.
fn is_fence(c: &[char], s: usize, e: usize, closing: bool) -> bool {
    let mut k = s;
    while k < e && k - s < 3 && c[k] == ' ' {
        k += 1;
    }
    let run = c[k..e].iter().take_while(|&&x| x == '`').count();
    run >= 3 && c[k + run..e].iter().all(|&x| if closing { x == ' ' } else { x != '`' })
}

impl Parser<'_> {
    fn push(&mut self, kind: Kind, s: usize, e: usize) {
        if e > s {
            self.out.push((kind, s, e));
        }
    }

    fn skip_spaces(&self, mut k: usize, e: usize) -> usize {
        while k < e && self.c[k] == ' ' {
            k += 1;
        }
        k
    }

    fn blocks(&mut self) {
        let c = self.c;
        let n = c.len();
        let mut fence: Option<usize> = None;
        let mut i = 0;
        while i < n {
            let nl = c[i..].iter().position(|&x| x == '\n').map_or(n, |p| i + p);
            let e = if nl > i && c[nl - 1] == '\r' { nl - 1 } else { nl };
            if is_fence(c, i, e, fence.is_some()) {
                self.push(Kind::CodeFence, i, e);
                match fence.take() {
                    Some(start) => self.push(Kind::CodeBlock, start, e),
                    None => fence = Some(i),
                }
            } else if fence.is_none() {
                self.line(i, e);
            }
            i = nl + 1;
        }
        if let Some(start) = fence {
            self.push(Kind::CodeBlock, start, n);
        }
    }

    fn line(&mut self, s: usize, e: usize) {
        let c = self.c;
        let mut k = s;
        while k < e && k - s < 3 && c[k] == ' ' {
            k += 1;
        }
        if k == e {
            return;
        }
        if matches!(c[k], '-' | '*' | '_') {
            let run = c[k..e].iter().take_while(|&&x| x == c[k]).count();
            if run >= 3 && self.skip_spaces(k + run, e) == e {
                return self.push(Kind::Divider, s, e);
            }
        }
        if c[k] == '#' {
            let h = c[k..e].iter().take_while(|&&x| x == '#').count();
            if h <= 6 && k + h < e && c[k + h] == ' ' {
                let m = self.skip_spaces(k + h, e);
                self.push(Kind::Heading(h as u8), s, e);
                self.push(Kind::Marker, k, m);
                return self.inline(m, e);
            }
        }
        if c[s] == '>' {
            let m = if s + 1 < e && c[s + 1] == ' ' { s + 2 } else { s + 1 };
            self.push(Kind::Quote, s, e);
            self.push(Kind::Marker, s, m);
            return self.inline(m, e);
        }
        let k = self.skip_spaces(s, e);
        if k == e {
            return;
        }
        if matches!(c[k], '-' | '*' | '+') && k + 1 < e && c[k + 1] == ' ' {
            let after = self.skip_spaces(k + 1, e);
            let boxed = after + 2 < e
                && c[after] == '['
                && matches!(c[after + 1], ' ' | 'x' | 'X')
                && c[after + 2] == ']'
                && (after + 3 == e || c[after + 3] == ' ');
            if boxed {
                let checked = c[after + 1] != ' ';
                let content = (after + 4).min(e);
                self.push(Kind::Marker, k, after);
                self.push(Kind::TaskBox { checked }, after, after + 3);
                self.push(Kind::ListContent, content, e);
                if checked {
                    self.push(Kind::TaskDone, content, e);
                }
                return self.inline(content, e);
            }
            self.push(Kind::Bullet, k, k + 1);
            self.push(Kind::ListContent, after, e);
            return self.inline(after, e);
        }
        let digits = c[k..e].iter().take_while(|x| x.is_ascii_digit()).count();
        let d = k + digits;
        if (1..=9).contains(&digits) && d + 1 < e && matches!(c[d], '.' | ')') && c[d + 1] == ' ' {
            let after = self.skip_spaces(d + 1, e);
            self.push(Kind::Number, k, d + 1);
            self.push(Kind::ListContent, after, e);
            return self.inline(after, e);
        }
        self.inline(s, e)
    }

    /// Code spans, links and escapes first (their characters become literal),
    /// then `**`, `~~`, and last `*` / `_`.
    fn inline(&mut self, a: usize, b: usize) {
        let c = self.c;
        let mut lit = vec![false; b - a];
        let mut i = a;
        while i < b {
            match c[i] {
                '\\' if i + 1 < b && c[i + 1].is_ascii_punctuation() => {
                    self.push(Kind::Marker, i, i + 1);
                    lit[i - a] = true;
                    lit[i + 1 - a] = true;
                    i += 2;
                }
                '`' => {
                    let n = c[i..b].iter().take_while(|&&x| x == '`').count();
                    let mut j = i + n;
                    let mut close = None;
                    while j < b {
                        let r = if c[j] == '`' { c[j..b].iter().take_while(|&&x| x == '`').count() } else { 0 };
                        if r == n {
                            close = Some(j);
                            break;
                        }
                        j += r.max(1);
                    }
                    let Some(j) = close else {
                        i += n;
                        continue;
                    };
                    self.push(Kind::Marker, i, i + n);
                    self.push(Kind::Code, i + n, j);
                    self.push(Kind::Marker, j, j + n);
                    lit[i - a..j + n - a].fill(true);
                    i = j + n;
                }
                '[' => match self.link(i, b) {
                    Some(end) => {
                        lit[i - a..end - a].fill(true);
                        i = end;
                    }
                    None => i += 1,
                },
                _ => i += 1,
            }
        }
        self.pairs(a, b, &mut lit, '*', 2, Kind::Bold);
        self.pairs(a, b, &mut lit, '~', 2, Kind::Strike);
        self.pairs(a, b, &mut lit, '*', 1, Kind::Italic);
        self.pairs(a, b, &mut lit, '_', 1, Kind::Italic);
    }

    /// `[text](url)` at `i`: emits the spans and returns the index after it.
    fn link(&mut self, i: usize, b: usize) -> Option<usize> {
        let c = self.c;
        let close = i + 1 + c[i + 1..b].iter().position(|&x| x == ']')?;
        if close == i + 1 || close + 1 >= b || c[close + 1] != '(' {
            return None;
        }
        let end = close + 2 + c[close + 2..b].iter().position(|&x| x == ')')?;
        if end == close + 2 || c[close + 2..end].iter().any(|x| x.is_whitespace()) {
            return None;
        }
        self.push(Kind::Marker, i, i + 1);
        self.push(Kind::LinkText, i + 1, close);
        self.push(Kind::Marker, close, end + 1);
        self.push(Kind::LinkUrl, close + 2, end);
        Some(end + 1)
    }

    /// Pairs of a delimiter run of exactly `n` `ch`s (longer runs are literal).
    // ponytail: first valid closer wins, no CommonMark delimiter stack, and an
    // unmatched opener scans to line end, so one 64 KiB line of `*a *a ...` is
    // O(n^2) on the main thread. Upgrade path: a delimiter stack.
    fn pairs(&mut self, a: usize, b: usize, lit: &mut [bool], ch: char, n: usize, kind: Kind) {
        let c = self.c;
        let run = |lit: &[bool], i: usize| (i..b).take_while(|&j| c[j] == ch && !lit[j - a]).count();
        let mut i = a;
        while i < b {
            if c[i] != ch || lit[i - a] {
                i += 1;
                continue;
            }
            let r = run(lit, i);
            let o = i + n;
            let opens = r == n && o < b && !c[o].is_whitespace() && !(ch == '_' && i > a && c[i - 1].is_alphanumeric());
            if !opens {
                i += r;
                continue;
            }
            let mut j = o;
            let mut close = None;
            while j < b {
                if c[j] != ch || lit[j - a] {
                    j += 1;
                    continue;
                }
                let r2 = run(lit, j);
                if r2 == n
                    && j > o
                    && !c[j - 1].is_whitespace()
                    && !(ch == '_' && j + n < b && c[j + n].is_alphanumeric())
                {
                    close = Some(j);
                    break;
                }
                j += r2;
            }
            let Some(j) = close else {
                i += r;
                continue;
            };
            self.push(Kind::Marker, i, o);
            self.push(kind, o, j);
            self.push(Kind::Marker, j, j + n);
            lit[i - a..o - a].fill(true);
            lit[j - a..j + n - a].fill(true);
            i = j + n;
        }
    }
}

fn parse(c: &[char]) -> Vec<Raw> {
    let mut p = Parser { c, out: Vec::new() };
    p.blocks();
    // Stable: equal start and length keep emission order (ListContent before TaskDone).
    p.out.sort_by(|x, y| x.1.cmp(&y.1).then((y.2 - y.1).cmp(&(x.2 - x.1))));
    p.out
}

/// Every styled range in `text`, sorted by start, longer first.
pub fn spans(text: &str) -> Vec<Span> {
    let chars: Vec<char> = text.chars().collect();
    let mut offsets = Vec::with_capacity(chars.len() + 1);
    let mut at = 0u32;
    for c in &chars {
        offsets.push(at);
        at += c.len_utf16() as u32;
    }
    offsets.push(at);
    parse(&chars)
        .into_iter()
        .map(|(kind, s, e)| Span { kind, start: offsets[s], len: offsets[e] - offsets[s] })
        .collect()
}

/// `text` with the marks removed and the line breaks kept, for previews.
pub fn plain_text(text: &str) -> String {
    let c: Vec<char> = text.chars().collect();
    let mut gone = vec![false; c.len()];
    for (kind, s, mut e) in parse(&c) {
        match kind {
            Kind::CodeFence => {
                if c.get(e) == Some(&'\r') && c.get(e + 1) == Some(&'\n') {
                    e += 1;
                }
                if c.get(e) == Some(&'\n') {
                    e += 1;
                }
            }
            Kind::Bullet => {
                while c.get(e) == Some(&' ') {
                    e += 1;
                }
            }
            Kind::TaskBox { .. } if c.get(e) == Some(&' ') => e += 1,
            Kind::Marker | Kind::TaskBox { .. } | Kind::Divider => {}
            _ => continue,
        }
        gone[s..e].fill(true);
    }
    c.iter().zip(&gone).filter(|(_, g)| !**g).map(|(ch, _)| ch).collect()
}

#[cfg(test)]
mod tests {
    use super::Kind::*;
    use super::*;

    fn s(kind: Kind, start: u32, len: u32) -> Span {
        Span { kind, start, len }
    }

    #[test]
    fn inline_marks() {
        assert_eq!(spans("Ship **rich** text"), [s(Marker, 5, 2), s(Bold, 7, 4), s(Marker, 11, 2)]);
        assert!(spans("5 * 3 * 2").is_empty());
        assert!(spans("snake_case_name and __init__").is_empty());
        assert_eq!(spans("a *b* c"), [s(Marker, 2, 1), s(Italic, 3, 1), s(Marker, 4, 1)]);
        assert_eq!(spans("`**x**`"), [s(Marker, 0, 1), s(Code, 1, 5), s(Marker, 6, 1)]);
        assert_eq!(
            spans("[guide](https://x.y)"),
            [s(Marker, 0, 1), s(LinkText, 1, 5), s(Marker, 6, 14), s(LinkUrl, 8, 11)]
        );
        assert_eq!(spans("\\*not\\*"), [s(Marker, 0, 1), s(Marker, 5, 1)]);
        assert!(spans("**unclosed").is_empty());
        assert!(spans("** spaced**").is_empty());
        assert!(spans("***x***").is_empty());
        assert_eq!(spans("~~x~~"), [s(Marker, 0, 2), s(Strike, 2, 1), s(Marker, 3, 2)]);
    }

    #[test]
    fn blocks() {
        assert_eq!(spans("# Heading"), [s(Heading(1), 0, 9), s(Marker, 0, 2)]);
        assert_eq!(spans("## Sub"), [s(Heading(2), 0, 6), s(Marker, 0, 3)]);
        assert!(spans("#tag").is_empty());
        assert!(spans("#").is_empty());
        assert_eq!(spans("- milk"), [s(Bullet, 0, 1), s(ListContent, 2, 4)]);
        assert_eq!(
            spans("  - [x] done"),
            [s(Marker, 2, 2), s(TaskBox { checked: true }, 4, 3), s(ListContent, 8, 4), s(TaskDone, 8, 4)]
        );
        assert_eq!(spans("- [ ]"), [s(Marker, 0, 2), s(TaskBox { checked: false }, 2, 3)]);
        assert_eq!(spans("1. one"), [s(Number, 0, 2), s(ListContent, 3, 3)]);
        assert_eq!(spans("> quote"), [s(Quote, 0, 7), s(Marker, 0, 2)]);
        assert_eq!(spans("```sh\ncode\n```"), [s(CodeBlock, 0, 14), s(CodeFence, 0, 5), s(CodeFence, 11, 3)]);
        assert_eq!(spans("```\n**x**"), [s(CodeBlock, 0, 9), s(CodeFence, 0, 3)]);
        assert_eq!(spans("---"), [s(Divider, 0, 3)]);
        assert_eq!(spans("Title\n---"), [s(Divider, 6, 3)]);
    }

    #[test]
    fn blank_lines_and_fences() {
        assert!(spans("    ").is_empty());
        assert!(spans("a\n    ").is_empty());
        assert_eq!(plain_text("a\n    "), "a\n    ");
        assert_eq!(spans("```x``` y"), [s(Marker, 0, 3), s(Code, 3, 1), s(Marker, 4, 3)]);
        assert_eq!(spans("```\na\n```sh\nb\n```"), [s(CodeBlock, 0, 17), s(CodeFence, 0, 3), s(CodeFence, 14, 3)]);
        assert_eq!(spans("```\r\na\r\n```"), [s(CodeBlock, 0, 11), s(CodeFence, 0, 3), s(CodeFence, 8, 3)]);
    }

    #[test]
    fn more_inline_and_numbers() {
        assert_eq!(
            spans("**a** and **b**"),
            [s(Marker, 0, 2), s(Bold, 2, 1), s(Marker, 3, 2), s(Marker, 10, 2), s(Bold, 12, 1), s(Marker, 13, 2)]
        );
        assert_eq!(
            spans("[x](y) **z**"),
            [
                s(Marker, 0, 1),
                s(LinkText, 1, 1),
                s(Marker, 2, 4),
                s(LinkUrl, 4, 1),
                s(Marker, 7, 2),
                s(Bold, 9, 1),
                s(Marker, 10, 2)
            ]
        );
        assert_eq!(spans("1) one"), [s(Number, 0, 2), s(ListContent, 3, 3)]);
    }

    #[test]
    fn offsets_and_line_ends() {
        assert_eq!(
            spans("কাজ **বাংলা** 🦊 *x*"),
            [s(Marker, 4, 2), s(Bold, 6, 5), s(Marker, 11, 2), s(Marker, 17, 1), s(Italic, 18, 1), s(Marker, 19, 1)]
        );
        assert_eq!(spans("**a**\r\nb"), [s(Marker, 0, 2), s(Bold, 2, 1), s(Marker, 3, 2)]);
    }

    #[test]
    fn plain_text_drops_marks() {
        assert_eq!(
            plain_text("# Title\n- [ ] buy **milk**\n1. one\n```\ncode\n```\nsee [docs](http://a) #tag"),
            "Title\nbuy milk\n1. one\ncode\nsee docs #tag"
        );
        assert_eq!(plain_text("a\n---\nb"), "a\n\nb");
    }
}
