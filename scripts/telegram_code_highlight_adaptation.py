"""Reviewed exact native highlighter budget/cancellation adaptation; no I/O.

MIT libprisma and Boost1.0 source notices are retained by preparation.
"""
import hashlib

SOURCE_SHA256 = {'libprisma/Highlight.h': '22356c382f007520e2d5815868b9a7b7744cf7c255290dee93a11368d2a7022c', 'libprisma/Highlight.cpp': 'e6dc4394d9bbddb2ef73cee87aa6e93aad82b684e795ae3972e1f50b7823f897', 'libprisma/LanguageTree.cpp': '44777f8382584dda3d35cda26f08082dec394375f642d5103456bf58f6780aa8', 'libprisma/SyntaxHighlighter.cpp': '76db11961c83a18d86e9f2069ec0ad78761ea544209f4fda9e0ee36bf490cb6e', 'libprisma/TokenList.cpp': '25cbcc4dd18c3c8f917d7581afceab75fa603593372860a3d08a0c0b7db3ed01', 'libprisma/TokenList.h': 'eafd6162e091c26173ab204aaa0367e0eaf1deeba954fe1ef5f9fa7265f72ebd', 'regex/include/boost/regex/v5/perl_matcher_common.hpp': 'ab4b4a8106e62fa200ea46b1f528fe123ca40256a7b84bbfeb144fcb704321f3', 'regex/include/boost/regex/v5/perl_matcher_non_recursive.hpp': '06cbb94fd2a37ced8c7e41e0c22a8553f681c9529c9958529ba534dd23526ada', 'regex/include/boost/regex/v5/perl_matcher.hpp': 'a1fe0d5e65ca269cef3f85f40d14db3c3f943fb06a96ed2ff79577b82fc67023', 'libprisma/SyntaxHighlighter.h': '9efe2f67c1cd84f438dadff6340d7d77db043ed6011e4f4275163617d288af83'}
ADAPTED_SHA256 = {'libprisma/Highlight.h': '8de39a85c63689ce8ace02baf3905458decdb3f4f9d70910b1cab5cd811894bc', 'libprisma/Highlight.cpp': '48d0a43e1aed380106cb6f98dafc2321d417c3179f00fe87f1b687a9280c493e', 'libprisma/LanguageTree.cpp': 'e0c9ee559238b5e0b945b79ec7801f0e914bcc0682270b0c0cbfe6561e2f5b45', 'libprisma/SyntaxHighlighter.cpp': 'fc1e856490840e5d1b0325dab412fefb0abf7bb1ccf97746037067beb779af29', 'libprisma/TokenList.cpp': '1e95e07d555349abbd099d104c82706362cea3188f6af2778e3e930b5ed7f43d', 'libprisma/TokenList.h': '22c4a4ce462441b3705f3f2653595194d1142421ef2d15b2120c93b19ea341ea', 'regex/include/boost/regex/v5/perl_matcher_common.hpp': '47419adb13cc5f30cebb935663dc2870fc23af1a589500305137b8f9d5da0474', 'regex/include/boost/regex/v5/perl_matcher_non_recursive.hpp': '0587ace9eb8836e370c4688ca7f9ba143cb4bbf1108ec1a3afecaded12e26cf6', 'regex/include/boost/regex/v5/perl_matcher.hpp': '8c6301b5f880b44a73fcb1299de6d6deaf33f04555d7674b9eaec617d0711e3c', 'libprisma/SyntaxHighlighter.h': '758fe26efffe997c104fc7003ef30eb0e7238909f2f959f31f9ac0b244ddfaa3'}

def _replace(source: str, before: str, after: str, count: int = 1) -> str:
    if source.count(before) != count:
        raise ValueError("Unexpected pinned native adaptation marker")
    return source.replace(before, after)


def _rewrite(path: str, source: str) -> str:
    if path == "libprisma/Highlight.h":
        source = '#include "MakoshPrismaBudget.h"\n' + source
        source = _replace(source, "std::shared_ptr<LanguageTree> m_tree;", "std::weak_ptr<LanguageTree> m_tree;", 2)
        return _replace(source, "        boost::cmatch m;", "        mk_prisma_checkpoint();\n        boost::cmatch m;")
    if path == "libprisma/Highlight.cpp":
        for kind in ("Grammar", "Pattern"):
            source = _replace(source, f"    return m_tree->resolve{kind}(m_path);",
                "    auto tree = m_tree.lock();\n    if (!tree) throw MKPrismaAbort();\n" +
                f"    return tree->resolve{kind}(m_path);")
        return source
    if path == "libprisma/LanguageTree.cpp":
        return _replace(source, "    for (int i = 0; i < count; ++i)\n    {",
            "    for (int i = 0; i < count; ++i)\n    {\n        mk_prisma_checkpoint();", 3)
    if path == "libprisma/SyntaxHighlighter.cpp":
        source = _replace(source, "std::map<std::string, std::string> SyntaxHighlighter::languages() const",
            "bool SyntaxHighlighter::supports(const std::string& language) const\n{\n    return m_tree->find(language) != nullptr;\n}\n\nstd::map<std::string, std::string> SyntaxHighlighter::languages() const")
        source = _replace(source, "    TokenList tokenList(text);\n    try {\n        matchGrammar(text, tokenList, grammar, tokenList.head, 0, nullptr);\n    } catch (...) {\n    }",
            "    MKPrismaDepthGuard depth;\n    TokenList tokenList(text);\n    matchGrammar(text, tokenList, grammar, tokenList.head, 0, nullptr);")
        source = _replace(source, "    for (const auto& token : grammar->tokens)\n    {",
            "    MKPrismaDepthGuard depth;\n    for (const auto& token : grammar->tokens)\n    {\n        mk_prisma_checkpoint();")
        source = _replace(source, "        for (auto j = token.cbegin(); j != token.cend(); ++j)\n        {",
            "        for (auto j = token.cbegin(); j != token.cend(); ++j)\n        {\n            mk_prisma_checkpoint();")
        return _replace(source, "            {\n                if (rematch && pos >= rematch->reach)",
            "            {\n                mk_prisma_checkpoint();\n                if (rematch && pos >= rematch->reach)")
    if path == "libprisma/SyntaxHighlighter.h":
        return _replace(source, "    std::map<std::string, std::string> languages() const;",
            "    bool supports(const std::string& language) const;\n\n    std::map<std::string, std::string> languages() const;")
    if path == "libprisma/TokenList.cpp":
        source = '#include "MakoshPrismaBudget.h"\n' + source
        source = _replace(source, "    : head(new TokenListNode())", "    : head((mk_prisma_nodes(2), new TokenListNode()))")
        source = _replace(source,
            "    const TokenListPtr newNode = new Text(head, head, value);\n    head->next = newNode;",
            "    std::unique_ptr<TokenListNode> sentinel(head);\n    const TokenListPtr newNode = new Text(head, head, value);\n    head->next = newNode;\n    sentinel.release();")
        return _replace(source, "    const TokenListPtr next = node->next;",
            "    mk_prisma_nodes(2);\n    const TokenListPtr next = node->next;", 2)
    if path == "libprisma/TokenList.h":
        return _replace(source, "    TokenList(TokenList&& old) noexcept", "    TokenList(TokenList&& old)")
    if path == "regex/include/boost/regex/v5/perl_matcher_common.hpp":
        source = '#include "MakoshPrismaBudget.h"\n' + source
        source = _replace(source, "   max_state_count = states;",
            "   max_state_count = (std::min)(states, static_cast<std::ptrdiff_t>(BOOST_REGEX_MAX_STATE_COUNT));", 2)
        source = _replace(source, "   catch(...)\n   {\n      // unwind all pushed states,",
            "   catch(...)\n   {\n      MKPrismaCleanupGuard cleanup;\n      // unwind all pushed states,", 2)
        source = _replace(source, "bool perl_matcher<BidiIterator, Allocator, traits>::match_prefix()\n{",
            "bool perl_matcher<BidiIterator, Allocator, traits>::match_prefix()\n{\n   mk_prisma_checkpoint();")
        source = _replace(source, "   while(true)\n   {", "   while(true)\n   {\n      mk_prisma_checkpoint();")
        source = _replace(source, "   while(position != last)\n   {",
            "   while(position != last)\n   {\n      mk_prisma_checkpoint();")
        return _replace(source, "   do\n   {\n      while((position != last) && traits_inst.isctype",
            "   do\n   {\n      mk_prisma_checkpoint();\n      while((position != last) && traits_inst.isctype")
    if path == "regex/include/boost/regex/v5/perl_matcher_non_recursive.hpp":
        source = '#include "MakoshPrismaBudget.h"\n' + source
        source = _replace(source, "++state_count;", "mk_prisma_checkpoint(); ++state_count;", 7)
        source = _replace(source, "bool perl_matcher<BidiIterator, Allocator, traits>::unwind(bool have_match)\n{",
            "bool perl_matcher<BidiIterator, Allocator, traits>::unwind(bool have_match)\n{\n   mk_prisma_checkpoint();")
        return _replace(source, "   while(pstate)\n   {", "   while(pstate)\n   {\n      mk_prisma_checkpoint();")
    if path == "regex/include/boost/regex/v5/perl_matcher.hpp":
        source = '#include "MakoshPrismaBudget.h"\n' + source
        return _replace(source, "{   \n   const charT* p = reinterpret_cast<const charT*>(set_+1);",
            "{   \n   mk_prisma_checkpoint();\n   const charT* p = reinterpret_cast<const charT*>(set_+1);")
    raise ValueError("Unknown native highlighter adaptation path")


def adapt_code_highlight_source(path: str, source: bytes) -> bytes:
    digest = hashlib.sha256(source).hexdigest()
    if path not in SOURCE_SHA256:
        raise ValueError("Unknown native highlighter adaptation path")
    if digest == ADAPTED_SHA256[path]:
        return source
    if digest != SOURCE_SHA256[path]:
        raise ValueError("Unexpected pinned native highlighter input")
    adapted = _rewrite(path, source.decode("utf-8")).encode("utf-8")
    if hashlib.sha256(adapted).hexdigest() != ADAPTED_SHA256[path]:
        raise ValueError("Unexpected adapted native highlighter digest")
    return adapted
