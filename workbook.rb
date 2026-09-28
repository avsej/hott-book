#!/usr/bin/env ruby
# Generates workbook.tex: every exercise of the book, numbered as in the book,
# each followed by blank space for a solution. What an exercise references is
# copied in front of it:
#
#   theorem, lemma, definition, remark, example, exercise
#                      -> its statement (not its proof)
#   equation, list item outside those
#                      -> the paragraph containing it
#   chapter, section   -> number and title only
#
#   ruby workbook.rb [--paper letter|ebook] [--pages N] [-o workbook.tex]
#   ruby workbook.rb --check [-o workbook.tex]  # after LaTeX: numbers match
#
# --paper P  page layout from opt-P.tex, as in the book (default letter).
# --pages N  pages per exercise (default 1): the exercise sits at the top of
#            its first page, the rest is left blank for the solution.
#
# The preamble is taken from exercise_solutions.tex, which inputs main.labels,
# so the book must be built first (`make workbook.pdf` does both).

require 'optparse'

pages = 1
paper = 'letter'
out = 'workbook.tex'
check = false
OptionParser.new do |o|
  o.on('--check', 'compare workbook.aux numbers with main.labels') { check = true }
  o.on('--paper P', 'layout from opt-P.tex (default letter)') { |p| paper = p }
  o.on('--pages N', Integer, 'pages per exercise (default 1)') { |n| pages = n }
  o.on('-o FILE', 'output file (default workbook.tex)') { |f| out = f }
end.parse!
abort '--pages must be at least 1' if pages < 1

# --check: after LaTeX has run, every exercise label in the workbook must carry
# the number the same label has in the book.
if check
  number = ->(file, prefix) { File.read(file).scan(/\\newlabel\{#{prefix}(ex:[^}@]*)\}\{\{([^}]*)\}/).to_h }
  book = number.('main.labels', '')
  wb = number.(out.sub(/\.tex\z/, '') + '.aux', 'wb:')
  bad = wb.reject { |k, v| book[k] == v }
  bad.each { |k, v| warn "#{k}: workbook #{v}, book #{book[k].inspect}" }
  abort "#{bad.size} exercise numbers differ from the book" unless bad.empty?
  puts "#{wb.size} labelled exercises match the book"
  exit
end

THEOREMS = %w[thm cor lem axiom defn rmk eg egs notes prop ex].freeze
DISPLAYS = %w[equation align gather multline narrowmultline flalign alignat eqnarray].freeze
SECTION = /\\(?:sub)*section\{(?:[^{}]|\{[^{}]*\})*\}\s*\\label\{([^}]*)\}/
REF = /\\(?:[cC]ref\*?|[cC]refrange|eqref|ref|autoref|pageref)\{([^}]*)\}/

Env = Struct.new(:name, :from, :to) # src[from...to] is \begin{name}...\end{name}

# Removes comments but keeps the `%`, so line-end space suppression survives.
def uncomment(tex) = tex.gsub(/(?<!\\)%.*$/, '%')

def environments(src)
  envs = []
  stack = []
  src.scan(/\\(begin|end)\{([^}]+)\}/) do
    m = Regexp.last_match
    if m[1] == 'begin'
      stack << [m[2], m.begin(0)]
    elsif (i = stack.rindex { |name, _| name == m[2] })
      name, from = stack.delete_at(i)
      envs << Env.new(name, from, m.end(0))
    end
  end
  envs
end

# Drops \begin and \end tokens that have no partner inside `tex`.
def balance(tex)
  stack = []
  drop = []
  tex.scan(/\\(begin|end)\{([^}]+)\}/) do
    m = Regexp.last_match
    if m[1] == 'begin'
      stack << [m[2], m.begin(0)...m.end(0)]
    elsif (i = stack.rindex { |name, _| name == m[2] })
      stack.slice!(i..)
    else
      drop << (m.begin(0)...m.end(0))
    end
  end
  (drop + stack.map(&:last)).sort_by(&:begin).reverse_each { |r| tex = tex[0...r.begin] + tex[r.end..] }
  tex
end

# Copied text keeps the book's equation numbers through \tag, since the
# workbook numbers nothing but exercises. Other labels get `prefix`, or are
# dropped when it is nil (an excerpt may be copied more than once).
def relabel(tex, prefix)
  tex = tex.gsub(/\\begin\{(#{DISPLAYS.join('|')})\}(.*?)\\end\{\1\}/m) do
    env, math = $1, $2
    "\\begin{#{env}*}#{math.gsub(/\\label\{([^}]*)\}/, '\tag{\ref*{\1}}')}\\end{#{env}*}"
  end
  tex.gsub(/\\symlabel\{[^}]*\}/, '') # entries of the symbol index, absent here
     .gsub(/\\label\{([^}]*)\}/) { prefix && "\\label{#{prefix}#{$1}}" }
end

# What a label points to: [:statement, file, env], [:paragraph, file, range]
# or [:heading].
def locate(label, sources)
  sources.each_with_index do |(src, envs), file|
    pos = src.index("\\label{#{label}}") or next
    around = envs.select { |e| e.from < pos && pos < e.to }
    if (thm = around.select { |e| THEOREMS.include?(e.name) }.max_by(&:from))
      return [:statement, file, thm]
    end
    outer = around.reject { |e| e.name == 'proof' }.min_by(&:from)
    return [:heading] unless outer
    from = src.rindex(/\n[ \t]*\n/, outer.from) || 0
    to = src.index(/\n[ \t]*\n/, outer.to) || src.size
    return [:paragraph, file, from...to]
  end
  nil
end

def statement(src, env, envs)
  text = src[env.from...env.to]
  title = text[/\A\\begin\{#{env.name}\}\s*\[((?:[^\[\]]|\[[^\]]*\])*)\]/, 1]
  body = text.sub(/\A\\begin\{#{env.name}\}\s*(\[((?:[^\[\]]|\[[^\]]*\])*)\])?/, '').delete_suffix("\\end{#{env.name}}")
  # The statement's own label: one not inside a nested environment.
  own = src[env.from...env.to].to_enum(:scan, /\\label\{([^}]*)\}/).map { [$1, env.from + $~.begin(0)] }
             .find { |_, pos| envs.none? { |e| e != env && env.from < e.from && e.from < pos && pos < e.to } }
  [own&.first, title, body]
end

main = File.read('main.tex')
mainmatter = main[/\\mainmatter(.*?)\\appendix/m, 1] or abort 'main.tex: no \\mainmatter ... \\appendix'

sources = []
chapters = []
uncomment(mainmatter).scan(/\\include\{([^}]+)\}/).flatten.each do |name|
  src = uncomment(File.read("#{name}.tex"))
  sources << [src, environments(src)]
  title = src[/\\chapter\{((?:[^{}]|\{[^{}]*\})*)\}/, 1] or next # unnumbered chapters
  exercises = src.scan(/\\begin\{ex\}(.*?)\\end\{ex\}/m).flatten
  chapters << [chapters.size + 1, name, title, exercises]
end

def excerpts(body, sources)
  own = body.scan(/\\label\{([^}]*)\}/).flatten
  labels = body.scan(REF).flatten.flat_map { |l| l.split(',') }.map(&:strip).uniq - own
  found = {}
  headings = []
  labels.each do |label|
    kind, file, where = locate(label, sources)
    case kind
    when nil then warn "reference to unknown label #{label}"
    when :heading then headings << label
    else (found[[file, kind == :statement ? where.from : where.begin]] ||= [kind, file, where, []])[3] << label
    end
  end
  parts = found.sort.map do |_, (kind, file, where, refs)|
    src, envs = sources[file]
    if kind == :statement
      label, title, text = statement(src, where, envs)
      head = "\\textbf{\\cref*{#{label || refs.first}}}#{" (#{title})" if title}."
    else
      section = src[0...where.begin].scan(SECTION).flatten.last
      head = section ? "\\textbf{From \\cref*{#{section}}.}" : '\\textbf{From the book.}'
      text = balance(src[where])
    end
    "\\begin{leftbar}\\small\\noindent#{head}\\ #{relabel(text, nil).strip}\n\\end{leftbar}"
  end
  unless headings.empty?
    list = headings.map { |l| "\\cref*{#{l}} \\emph{\\nameref*{#{l}}}" }.join('; ')
    parts << "\\begin{leftbar}\\small\\noindent\\textbf{See the book:} #{list}.\\end{leftbar}"
  end
  parts.join("\n")
end

abort "opt-#{paper}.tex: no such layout" unless File.exist?("opt-#{paper}.tex")
# The preamble of exercise_solutions.tex with its letter font size and
# geometry replaced by the \OPT settings, which opt-#{paper}.tex defines along
# with \narrowequation and friends.
preamble = File.read('exercise_solutions.tex')[/\A.*?(?=\\title\{)/m] or abort 'exercise_solutions.tex: no \\title'
geometry = main[/^\\usepackage\[papersize=\{\\OPTpagesize\}.*?\]\{geometry\}/m] or abort 'main.tex: no \\OPT geometry'
preamble = "\\input{opt-#{paper}}\n" +
           preamble.sub(/^11pt\b/, '\OPTfontsize')
                   .sub(/^\\usepackage\[papersize=\{8\.5in,11in\}.*?\]\{geometry\}/m) { geometry }
blank_page = "\\newpage\\null\n"

File.open(out, 'w') do |f|
  f.puts '% AUTOGENERATED by workbook.rb -- do not edit'
  f.puts preamble
  f.puts <<~'TEX'
    \usepackage{framed} % leftbar: text copied from the book
    \hypersetup{pdftitle={Homotopy Type Theory: Workbook}}
    \title{Homotopy Type Theory\\[1ex]\large Workbook: exercises from the book}
    \date{}
    \begin{document}
    \maketitle
    \thispagestyle{empty}
  TEX
  chapters.each do |num, name, title, exercises|
    next if exercises.empty?
    f.puts "\n% ---- #{name}.tex"
    f.puts "\\clearpage\\setcounter{chapter}{#{num}}\\setcounter{ex}{0}"
    f.puts "\\section*{Chapter #{num}: #{title}}\\markboth{Chapter #{num}}{Chapter #{num}}"
    exercises.each_with_index do |body, i|
      f.puts '\\clearpage' unless i.zero?
      f.puts excerpts(body, sources)
      f.puts "\\begin{ex}#{relabel(body, 'wb:')}\\end{ex}"
      f.puts '\\markright{Exercise~\\theex}\\par\\medskip\\noindent\\textit{Solution.}'
      f.print blank_page * (pages - 1)
    end
  end
  f.puts '\\clearpage\\bibliographystyle{halpha}\\bibliography{references}', '\\end{document}'
end

warn "#{out}: #{chapters.sum { |c| c[3].size }} exercises"
