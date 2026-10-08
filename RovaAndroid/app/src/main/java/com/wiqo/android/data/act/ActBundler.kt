package com.wiqo.android.data.act

/** Builds one local page from the project's HTML, CSS and JavaScript. */
object ActBundler {
    private fun Regex.insertAtFirst(source: String, replacement: (String) -> String): String {
        val match = find(source) ?: return source
        return source.replaceRange(match.range, replacement(match.value))
    }
    private val head = Regex("<head[^>]*>", RegexOption.IGNORE_CASE)
    private val endHead = Regex("</head>", RegexOption.IGNORE_CASE)
    private val endBody = Regex("</body>", RegexOption.IGNORE_CASE)
    private val styleTag = Regex("<style\\b[^>]*>[\\s\\S]*?</style>", RegexOption.IGNORE_CASE)
    private val inlineScriptTag = Regex("<script\\b[^>]*>([\\s\\S]*?)</script>", RegexOption.IGNORE_CASE)
    private val bodyTag = Regex("<body[^>]*>([\\s\\S]*?)</body>", RegexOption.IGNORE_CASE)
    private val localStyle = Regex("<link\\b(?=[^>]*\\brel\\s*=\\s*['\"]?stylesheet)(?=[^>]*\\bhref\\s*=\\s*['\"]([^'\"]+)['\"])[^>]*>", RegexOption.IGNORE_CASE)
    private val localScript = Regex("<script\\b[^>]*\\bsrc\\s*=\\s*['\"]([^'\"]+)['\"][^>]*>\\s*</script>", setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL))

    fun page(project: ActProject): String? {
        if (project.kind != "web") return null
        val files = project.files
        val entryPath = if (files.containsKey("index.html")) "index.html" else files.keys.sorted().firstOrNull { it.endsWith(".html") } ?: return null
        val base = entryPath.substringBeforeLast('/', "")
        fun resolve(path: String): String? {
            val clean = path.removePrefix("./")
            return files[if (base.isEmpty()) clean else "$base/$clean"] ?: files[clean]
        }
        fun inlineAssets(source: String): String {
            val styles = localStyle.replace(source) { match ->
                resolve(match.groupValues[1])?.let { "<style>\n${it.replace("</style", "<\\/style", true)}\n</style>" } ?: match.value
            }
            return localScript.replace(styles) { match ->
                val url = match.groupValues[1]
                val code = resolve(url)
                if (code == null) match.value else {
                    val attrs = match.value.substringAfter("<script").substringBefore('>').replace(Regex("\\s*src\\s*=\\s*['\"][^'\"]+['\"]", RegexOption.IGNORE_CASE), "")
                    "<script$attrs>\n${code.replace("</script", "<\\/script", true)}\n</script>"
                }
            }
        }
        var html = inlineAssets(files.getValue(entryPath))
        val extras = files.keys.sorted().filter { it != entryPath && it.endsWith(".html") && (base.isEmpty() || it.startsWith("$base/")) }.take(8)
        if (extras.isNotEmpty()) {
            val styles = linkedSetOf<String>()
            val scripts = mutableListOf<String>()
            val sections = mutableListOf<String>()
            for (path in extras) {
                var page = inlineAssets(files[path].orEmpty())
                page = styleTag.replace(page) { block -> styles.add(block.value); "" }
                page = inlineScriptTag.replace(page) { block ->
                    val code = block.groupValues[1]
                    if (code.isNotBlank()) scripts.add(code)
                    ""
                }
                val body = bodyTag.find(page)?.groupValues?.get(1) ?: page.replace(Regex("<!doctype[^>]*>|</?html[^>]*>|<head[\\s\\S]*?</head>", RegexOption.IGNORE_CASE), "")
                val relative = path.removePrefix(if (base.isEmpty()) "" else "$base/")
                sections.add("<div data-wiqo-page=\"$relative\" style=\"display:none\">$body</div>")
            }
            val css = styles.joinToString("\n")
            html = if (endHead.containsMatchIn(html)) endHead.insertAtFirst(html) { "$css\n</head>" } else css + html
            val wrapped = scripts.joinToString("\n") { code ->
                "<script>(function(){try{\n${code.replace("</script", "<\\/script", true)}\n}catch(e){console.error(e)}})();</script>"
            }
            val tail = sections.joinToString("\n") + "\n" + wrapped + "\n<script>" + pageNav + "</script>"
            html = if (endBody.containsMatchIn(html)) endBody.insertAtFirst(html) { "$tail\n</body>" } else html + tail
        }
        if (!Regex("<meta[^>]+name=['\"]viewport['\"]", RegexOption.IGNORE_CASE).containsMatchIn(html)) {
            val viewport = "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1, viewport-fit=cover\">"
            html = if (head.containsMatchIn(html)) head.insertAtFirst(html) { it + viewport } else viewport + html
        }
        val shim = """<script>(function(){var p='wiqo:${project.id}:';window.wiqoStore={get:function(k,f){try{var v=localStorage.getItem(p+k);return v===null?f:JSON.parse(v)}catch(e){return f}},set:function(k,v){try{localStorage.setItem(p+k,JSON.stringify(v))}catch(e){}}}})();</script>"""
        html = if (head.containsMatchIn(html)) head.insertAtFirst(html) { it + shim } else shim + html
        return html
    }

    private val pageNav = """(function(){var pages={};document.querySelectorAll('[data-wiqo-page]').forEach(function(n){pages[n.getAttribute('data-wiqo-page')]=n});var home=Array.prototype.filter.call(document.body.children,function(n){return !n.hasAttribute('data-wiqo-page')&&n.tagName!=='SCRIPT'&&n.tagName!=='STYLE'});function show(name){home.forEach(function(n){n.style.display=name==='index.html'?'':'none'});Object.keys(pages).forEach(function(k){pages[k].style.display=k===name?'':'none'});window.scrollTo(0,0)}document.addEventListener('click',function(e){var a=e.target&&e.target.closest?e.target.closest('a[href]'):null;if(!a)return;var m=(a.getAttribute('href')||'').match(/^(?:\.\/)?([^#?:]+\.html)(#.+)?$/i);if(!m)return;var name=m[1];if(name!=='index.html'&&!pages[name])return;e.preventDefault();show(name);if(m[2]){var t=document.getElementById(m[2].slice(1));if(t)t.scrollIntoView()}})})();"""
}
