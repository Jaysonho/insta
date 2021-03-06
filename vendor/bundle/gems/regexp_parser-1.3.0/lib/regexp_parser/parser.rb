require 'regexp_parser/expression'

class Regexp::Parser
  include Regexp::Expression
  include Regexp::Syntax

  class ParserError < StandardError; end

  class UnknownTokenTypeError < ParserError
    def initialize(type, token)
      super "Unknown token type #{type} #{token.inspect}"
    end
  end

  class UnknownTokenError < ParserError
    def initialize(type, token)
      super "Unknown #{type} token #{token.token}"
    end
  end

  def self.parse(input, syntax = "ruby/#{RUBY_VERSION}", &block)
    new.parse(input, syntax, &block)
  end

  def parse(input, syntax = "ruby/#{RUBY_VERSION}", &block)
    root = Root.build(options_from_input(input))

    self.root = root
    self.node = root
    self.nesting = [root]

    self.options_stack = [root.options]
    self.switching_options = false
    self.conditional_nesting = []

    self.captured_group_counts = Hash.new(0)

    Regexp::Lexer.scan(input, syntax) do |token|
      parse_token(token)
    end

    if block_given?
      block.call(root)
    else
      root
    end
  end

  private

  attr_accessor :root, :node, :nesting,
                :options_stack, :switching_options, :conditional_nesting,
                :captured_group_counts

  def options_from_input(input)
    return {} unless input.is_a?(::Regexp)

    options = {}
    options[:i] = true if input.options & ::Regexp::IGNORECASE != 0
    options[:m] = true if input.options & ::Regexp::MULTILINE  != 0
    options[:x] = true if input.options & ::Regexp::EXTENDED   != 0
    options
  end

  def nest(exp)
    nesting.push(exp)
    node << exp
    update_transplanted_subtree(exp, node)
    self.node = exp
  end

  # subtrees are transplanted to build Alternations, Intersections, Ranges
  def update_transplanted_subtree(exp, new_parent)
    exp.nesting_level = new_parent.nesting_level + 1
    exp.respond_to?(:each) &&
      exp.each { |subexp| update_transplanted_subtree(subexp, exp) }
  end

  def decrease_nesting
    while nesting.last.is_a?(SequenceOperation)
      nesting.pop
      self.node = nesting.last
    end
    nesting.pop
    yield(node) if block_given?
    self.node = nesting.last
    self.node = node.last if node.last.is_a?(SequenceOperation)
  end

  def nest_conditional(exp)
    conditional_nesting.push(exp)
    nest(exp)
  end

  def parse_token(token)
    close_completed_character_set_range

    case token.type
    when :meta;         meta(token)
    when :quantifier;   quantifier(token)
    when :anchor;       anchor(token)
    when :escape;       escape(token)
    when :group;        group(token)
    when :assertion;    group(token)
    when :set;          set(token)
    when :type;         type(token)
    when :backref;      backref(token)
    when :conditional;  conditional(token)
    when :keep;         keep(token)

    when :posixclass, :nonposixclass
      posixclass(token)
    when :property, :nonproperty
      property(token)

    when :literal
      node << Literal.new(token, active_opts)
    when :free_space
      free_space(token)

    else
      raise UnknownTokenTypeError.new(token.type, token)
    end
  end

  def set(token)
    case token.token
    when :open
      open_set(token)
    when :close
      close_set
    when :negate
      negate_set
    when :range
      range(token)
    when :intersection
      intersection(token)
    when :collation, :equivalent
      node << Literal.new(token, active_opts)
    else
      raise UnknownTokenError.new('CharacterSet', token)
    end
  end

  def meta(token)
    case token.token
    when :dot
      node << CharacterType::Any.new(token, active_opts)
    when :alternation
      sequence_operation(Alternation, token)
    else
      raise UnknownTokenError.new('Meta', token)
    end
  end

  def backref(token)
    case token.token
    when :name_ref
      node << Backreference::Name.new(token, active_opts)
    when :name_recursion_ref
      node << Backreference::NameRecursionLevel.new(token, active_opts)
    when :name_call
      node << Backreference::NameCall.new(token, active_opts)
    when :number, :number_ref
      node << Backreference::Number.new(token, active_opts)
    when :number_rel_ref
      node << Backreference::NumberRelative.new(token, active_opts)
    when :number_recursion_ref
      node << Backreference::NumberRecursionLevel.new(token, active_opts)
    when :number_call
      node << Backreference::NumberCall.new(token, active_opts)
    when :number_rel_call
      node << Backreference::NumberCallRelative.new(token, active_opts)
    else
      raise UnknownTokenError.new('Backreference', token)
    end
  end

  def type(token)
    case token.token
    when :digit
      node << CharacterType::Digit.new(token, active_opts)
    when :nondigit
      node << CharacterType::NonDigit.new(token, active_opts)
    when :hex
      node << CharacterType::Hex.new(token, active_opts)
    when :nonhex
      node << CharacterType::NonHex.new(token, active_opts)
    when :space
      node << CharacterType::Space.new(token, active_opts)
    when :nonspace
      node << CharacterType::NonSpace.new(token, active_opts)
    when :word
      node << CharacterType::Word.new(token, active_opts)
    when :nonword
      node << CharacterType::NonWord.new(token, active_opts)
    when :linebreak
      node << CharacterType::Linebreak.new(token, active_opts)
    when :xgrapheme
      node << CharacterType::ExtendedGrapheme.new(token, active_opts)
    else
      raise UnknownTokenError.new('CharacterType', token)
    end
  end

  def conditional(token)
    case token.token
    when :open
      nest_conditional(Conditional::Expression.new(token, active_opts))
    when :condition
      conditional_nesting.last.condition = Conditional::Condition.new(token, active_opts)
      conditional_nesting.last.branch
    when :separator
      conditional_nesting.last.branch
      self.node = conditional_nesting.last.branches.last
    when :close
      conditional_nesting.pop
      decrease_nesting

      self.node =
        if conditional_nesting.empty?
          nesting.last
        else
          conditional_nesting.last
        end
    else
      raise UnknownTokenError.new('Conditional', token)
    end
  end

  def posixclass(token)
    node << PosixClass.new(token)
  end

  include Regexp::Expression::UnicodeProperty

  def property(token)
    case token.token
    when :alnum;                  node << Alnum.new(token, active_opts)
    when :alpha;                  node << Alpha.new(token, active_opts)
    when :ascii;                  node << Ascii.new(token, active_opts)
    when :blank;                  node << Blank.new(token, active_opts)
    when :cntrl;                  node << Cntrl.new(token, active_opts)
    when :digit;                  node << Digit.new(token, active_opts)
    when :graph;                  node << Graph.new(token, active_opts)
    when :lower;                  node << Lower.new(token, active_opts)
    when :print;                  node << Print.new(token, active_opts)
    when :punct;                  node << Punct.new(token, active_opts)
    when :space;                  node << Space.new(token, active_opts)
    when :upper;                  node << Upper.new(token, active_opts)
    when :word;                   node << Word.new(token, active_opts)
    when :xdigit;                 node << Xdigit.new(token, active_opts)
    when :xposixpunct;            node << XPosixPunct.new(token, active_opts)

    # only in Oniguruma (old rubies)
    when :newline;                node << Newline.new(token, active_opts)

    when :any;                    node << Any.new(token, active_opts)
    when :assigned;               node << Assigned.new(token, active_opts)

    when :letter;                 node << Letter::Any.new(token, active_opts)
    when :cased_letter;           node << Letter::Cased.new(token, active_opts)
    when :uppercase_letter;       node << Letter::Uppercase.new(token, active_opts)
    when :lowercase_letter;       node << Letter::Lowercase.new(token, active_opts)
    when :titlecase_letter;       node << Letter::Titlecase.new(token, active_opts)
    when :modifier_letter;        node << Letter::Modifier.new(token, active_opts)
    when :other_letter;           node << Letter::Other.new(token, active_opts)

    when :mark;                   node << Mark::Any.new(token, active_opts)
    when :combining_mark;         node << Mark::Combining.new(token, active_opts)
    when :nonspacing_mark;        node << Mark::Nonspacing.new(token, active_opts)
    when :spacing_mark;           node << Mark::Spacing.new(token, active_opts)
    when :enclosing_mark;         node << Mark::Enclosing.new(token, active_opts)

    when :number;                 node << Number::Any.new(token, active_opts)
    when :decimal_number;         node << Number::Decimal.new(token, active_opts)
    when :letter_number;          node << Number::Letter.new(token, active_opts)
    when :other_number;           node << Number::Other.new(token, active_opts)

    when :punctuation;            node << Punctuation::Any.new(token, active_opts)
    when :connector_punctuation;  node << Punctuation::Connector.new(token, active_opts)
    when :dash_punctuation;       node << Punctuation::Dash.new(token, active_opts)
    when :open_punctuation;       node << Punctuation::Open.new(token, active_opts)
    when :close_punctuation;      node << Punctuation::Close.new(token, active_opts)
    when :initial_punctuation;    node << Punctuation::Initial.new(token, active_opts)
    when :final_punctuation;      node << Punctuation::Final.new(token, active_opts)
    when :other_punctuation;      node << Punctuation::Other.new(token, active_opts)

    when :separator;              node << Separator::Any.new(token, active_opts)
    when :space_separator;        node << Separator::Space.new(token, active_opts)
    when :line_separator;         node << Separator::Line.new(token, active_opts)
    when :paragraph_separator;    node << Separator::Paragraph.new(token, active_opts)

    when :symbol;                 node << Symbol::Any.new(token, active_opts)
    when :math_symbol;            node << Symbol::Math.new(token, active_opts)
    when :currency_symbol;        node << Symbol::Currency.new(token, active_opts)
    when :modifier_symbol;        node << Symbol::Modifier.new(token, active_opts)
    when :other_symbol;           node << Symbol::Other.new(token, active_opts)

    when :other;                  node << Codepoint::Any.new(token, active_opts)
    when :control;                node << Codepoint::Control.new(token, active_opts)
    when :format;                 node << Codepoint::Format.new(token, active_opts)
    when :surrogate;              node << Codepoint::Surrogate.new(token, active_opts)
    when :private_use;            node << Codepoint::PrivateUse.new(token, active_opts)
    when :unassigned;             node << Codepoint::Unassigned.new(token, active_opts)

    when *Token::UnicodeProperty::Age
      node << Age.new(token, active_opts)

    when *Token::UnicodeProperty::Derived
      node << Derived.new(token, active_opts)

    when *Token::UnicodeProperty::Emoji
      node << Emoji.new(token, active_opts)

    when *Token::UnicodeProperty::Script
      node << Script.new(token, active_opts)

    when *Token::UnicodeProperty::UnicodeBlock
      node << Block.new(token, active_opts)

    else
      raise UnknownTokenError.new('UnicodeProperty', token)
    end
  end

  def anchor(token)
    case token.token
    when :bol
      node << Anchor::BeginningOfLine.new(token, active_opts)
    when :eol
      node << Anchor::EndOfLine.new(token, active_opts)
    when :bos
      node << Anchor::BOS.new(token, active_opts)
    when :eos
      node << Anchor::EOS.new(token, active_opts)
    when :eos_ob_eol
      node << Anchor::EOSobEOL.new(token, active_opts)
    when :word_boundary
      node << Anchor::WordBoundary.new(token, active_opts)
    when :nonword_boundary
      node << Anchor::NonWordBoundary.new(token, active_opts)
    when :match_start
      node << Anchor::MatchStart.new(token, active_opts)
    else
      raise UnknownTokenError.new('Anchor', token)
    end
  end

  def escape(token)
    case token.token

    when :backspace
      node << EscapeSequence::Backspace.new(token, active_opts)

    when :escape
      node << EscapeSequence::AsciiEscape.new(token, active_opts)
    when :bell
      node << EscapeSequence::Bell.new(token, active_opts)
    when :form_feed
      node << EscapeSequence::FormFeed.new(token, active_opts)
    when :newline
      node << EscapeSequence::Newline.new(token, active_opts)
    when :carriage
      node << EscapeSequence::Return.new(token, active_opts)
    when :tab
      node << EscapeSequence::Tab.new(token, active_opts)
    when :vertical_tab
      node << EscapeSequence::VerticalTab.new(token, active_opts)

    when :hex
      node << EscapeSequence::Hex.new(token, active_opts)
    when :octal
      node << EscapeSequence::Octal.new(token, active_opts)
    when :codepoint
      node << EscapeSequence::Codepoint.new(token, active_opts)
    when :codepoint_list
      node << EscapeSequence::CodepointList.new(token, active_opts)

    when :control
      if token.text =~ /\A(?:\\C-\\M|\\c\\M)/
        node << EscapeSequence::MetaControl.new(token, active_opts)
      else
        node << EscapeSequence::Control.new(token, active_opts)
      end

    when :meta_sequence
      if token.text =~ /\A\\M-\\[Cc]/
        node << EscapeSequence::MetaControl.new(token, active_opts)
      else
        node << EscapeSequence::Meta.new(token, active_opts)
      end

    else
      # treating everything else as a literal
      node << EscapeSequence::Literal.new(token, active_opts)
    end
  end

  def keep(token)
    node << Keep::Mark.new(token, active_opts)
  end

  def free_space(token)
    case token.token
    when :comment
      node << Comment.new(token, active_opts)
    when :whitespace
      if node.last.is_a?(WhiteSpace)
        node.last.merge(WhiteSpace.new(token, active_opts))
      else
        node << WhiteSpace.new(token, active_opts)
      end
    else
      raise UnknownTokenError.new('FreeSpace', token)
    end
  end

  def quantifier(token)
    offset = -1
    target_node = node.expressions[offset]
    while target_node.is_a?(FreeSpace)
      target_node = node.expressions[offset -= 1]
    end

    target_node || raise(ArgumentError, 'No valid target found for '\
                                        "'#{token.text}' ")

    case token.token
    when :zero_or_one
      target_node.quantify(:zero_or_one, token.text, 0, 1, :greedy)
    when :zero_or_one_reluctant
      target_node.quantify(:zero_or_one, token.text, 0, 1, :reluctant)
    when :zero_or_one_possessive
      target_node.quantify(:zero_or_one, token.text, 0, 1, :possessive)

    when :zero_or_more
      target_node.quantify(:zero_or_more, token.text, 0, -1, :greedy)
    when :zero_or_more_reluctant
      target_node.quantify(:zero_or_more, token.text, 0, -1, :reluctant)
    when :zero_or_more_possessive
      target_node.quantify(:zero_or_more, token.text, 0, -1, :possessive)

    when :one_or_more
      target_node.quantify(:one_or_more, token.text, 1, -1, :greedy)
    when :one_or_more_reluctant
      target_node.quantify(:one_or_more, token.text, 1, -1, :reluctant)
    when :one_or_more_possessive
      target_node.quantify(:one_or_more, token.text, 1, -1, :possessive)

    when :interval
      interval(target_node, token)

    else
      raise UnknownTokenError.new('Quantifier', token)
    end
  end

  def interval(target_node, token)
    text = token.text
    mchr = text[text.length-1].chr =~ /[?+]/ ? text[text.length-1].chr : nil
    case mchr
    when '?'
      range_text = text[0...-1]
      mode = :reluctant
    when '+'
      range_text = text[0...-1]
      mode = :possessive
    else
      range_text = text
      mode = :greedy
    end

    range = range_text.gsub(/\{|\}/, '').split(',', 2)
    min = range[0].empty? ? 0 : range[0]
    max = range[1] ? (range[1].empty? ? -1 : range[1]) : min

    target_node.quantify(:interval, text, min.to_i, max.to_i, mode)
  end

  def group(token)
    case token.token
    when :options, :options_switch
      options_group(token)
    when :close
      close_group
    when :comment
      node << Group::Comment.new(token, active_opts)
    else
      open_group(token)
    end
  end

  def options_group(token)
    positive, negative = token.text.split('-', 2)
    negative ||= ''
    self.switching_options = token.token.equal?(:options_switch)

    opt_changes = {}
    new_active_opts = active_opts.dup

    # Negative options have precedence. E.g. /(?i-i)a/ is case-sensitive.
    %w[i m x].each do |flag|
      if positive.include?(flag)
        opt_changes[flag.to_sym] = new_active_opts[flag.to_sym] = true
      end
      if negative.include?(flag)
        opt_changes[flag.to_sym] = false
        new_active_opts.delete(flag.to_sym)
      end
    end

    # Any encoding flag overrides all previous encoding flags. If there are
    # multiple encoding flags in an options string, the last one wins.
    # E.g. /(?dau)\w/ matches UTF8 chars but /(?dua)\w/ only ASCII chars.
    if (flag = positive.reverse[/[adu]/])
      %w[a d u].each { |key| new_active_opts.delete(key.to_sym) }
      opt_changes[flag.to_sym] = new_active_opts[flag.to_sym] = true
    end

    options_stack << new_active_opts

    options_group = Group::Options.new(token, active_opts)
    options_group.option_changes = opt_changes

    nest(options_group)
  end

  def open_group(token)
    case token.token
    when :passive
      exp = Group::Passive.new(token, active_opts)
    when :atomic
      exp = Group::Atomic.new(token, active_opts)
    when :named
      exp = Group::Named.new(token, active_opts)
    when :capture
      exp = Group::Capture.new(token, active_opts)
    when :absence
      exp = Group::Absence.new(token, active_opts)

    when :lookahead
      exp = Assertion::Lookahead.new(token, active_opts)
    when :nlookahead
      exp = Assertion::NegativeLookahead.new(token, active_opts)
    when :lookbehind
      exp = Assertion::Lookbehind.new(token, active_opts)
    when :nlookbehind
      exp = Assertion::NegativeLookbehind.new(token, active_opts)

    else
      raise UnknownTokenError.new('Group type open', token)
    end

    if exp.capturing?
      exp.number          = total_captured_group_count + 1
      exp.number_at_level = captured_group_count_at_level + 1
      count_captured_group
    end

    # Push the active options to the stack again. This way we can simply pop the
    # stack for any group we close, no matter if it had its own options or not.
    options_stack << active_opts

    nest(exp)
  end

  def close_group
    options_stack.pop unless switching_options
    self.switching_options = false
    decrease_nesting
  end

  def open_set(token)
    token.token = :character
    nest(CharacterSet.new(token, active_opts))
  end

  def negate_set
    node.negate
  end

  def close_set
    decrease_nesting(&:close)
  end

  def range(token)
    exp = CharacterSet::Range.new(token, active_opts)
    scope = node.last.is_a?(CharacterSet::IntersectedSequence) ? node.last : node
    exp << scope.expressions.pop
    nest(exp)
  end

  def close_completed_character_set_range
    decrease_nesting if node.is_a?(CharacterSet::Range) && node.complete?
  end

  def intersection(token)
    sequence_operation(CharacterSet::Intersection, token)
  end

  def sequence_operation(klass, token)
    if node.last.is_a?(klass)
      self.node = node.last
    elsif !node.is_a?(klass)
      operator = klass.new(token, active_opts)
      sequence = operator.add_sequence
      sequence.expressions = node.expressions
      node.expressions = []
      nest(operator)
    end
    node.add_sequence
  end

  def active_opts
    options_stack.last
  end

  def total_captured_group_count
    captured_group_counts.values.reduce(0, :+)
  end

  def captured_group_count_at_level
    captured_group_counts[node.level]
  end

  def count_captured_group
    captured_group_counts[node.level] += 1
  end
end # module Regexp::Parser
