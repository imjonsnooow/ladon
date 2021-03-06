require 'ladon/modeler/graph'

module Ladon
  module Modeler
    # An extension of the Graph class. Unlike Graph instances, FiniteStateMachine
    # instances have a concept of a single "current state" that they are at.
    #
    # FiniteStateMachine instances are effectively executable Graph instances,
    # where the States types in the Graph can actually be instantiated
    # and transitions can be executed to change the machine's current state.
    class FiniteStateMachine < Graph
      # Creates a new instance.
      #
      # @raise [StandardError] If the +config+ is not a Ladon::Modeler::Config instance.
      #
      # @param [Ladon::Modeler::Config] config The object providing configuration for this new Graph model.
      # @return [FiniteStateMachine] The new graph instance.
      def initialize(config: Ladon::Config.new, timer: nil, logger: nil)
        super
        @current_state = nil
      end

      # Create an instance of the given state type. Subclass implementations can override
      # this method to customize the instantiation behavior to fit the requirements of the
      # +initialize+ method of the expected State types for the subclass FSM.
      #
      # @param [Object] state_class The state type to instantiate.
      # @return [Ladon::Modeler::State] An instance of the given +state_class+.
      def new_state_instance(state_class)
        @current_state = state_class.new
        @current_state.instance_variable_set(:@model, self)
        return @current_state
      end

      # Method used to change the current state to an instance of the specified state class.
      # If the given state class is not yet known to this FSM, +load_state_type+ will be called for the +state_class+.
      #
      # @param [Object] state_class The state type to use.
      # @param [LoadStrategy] strategy The strategy from LoadStrategy::ALL to use to load +state_class+, if necessary.
      # @return [State] The new +@current_state+ value.
      def use_state_type(state_class, strategy: LoadStrategy::LAZY)
        load_state_type(state_class, strategy: strategy) unless state_loaded?(state_class)
        @current_state = new_state_instance(state_class)
      end

      # Accessor for the +current_state+ instance variable.
      #
      # If a block is given, the block will be executed by yielding the +@current_state+,
      # instead of returning it.
      #
      # @yield [State] The current instance of the State type the machine is at.
      #
      # @return [State|Object] If no block is given, returns the +@current_state+.
      #   Otherwise, returns block return value
      def current_state
        return @current_state unless block_given?
        yield(@current_state)
      end

      # Make this FSM execute a transition from the +@current_state+.
      #
      # Transition executions consist of 5 phases:
      # - *Read* all known transitions available from the +@current_state+'s type
      # - *Prefilter* the results via +prefiltered_transitions+ method (accepts an optional block, see note below)
      # - *Validate* the prefiltered items via +valid_transitions+ to select only the currently valid options
      # - *Select* the transition to execute via FSM-level +selection_strategy+
      # - *Execute* the selected transition, updating this FSM's state to an instance of the transition's target type
      #
      # *Note:* see +prefiltered_transitions+ for more detail on how the +block+ is used, if given.
      #
      # *Note:* if the transitions for the +current_state+'s class have not been loaded, those transitions
      # will now be loaded (though their targets will not be auto-required unless the transition is used.)
      #
      # @raise [NoCurrentStateError] If the FSM has no +current_state+ it is operating within.
      # @raise [ArgumentError] If FSM-level +selection_strategy+ returns anything
      #   other than a single Transition instance.
      #
      # @param [LoadStrategy] strategy The load strategy for +@current_state+'s class' transitions, if they're
      #   not already loaded.
      # @param [KeywordArguments] **kwargs Arbitrary named arguments that will be provided
      #   to the 'when' and 'by' methods
      # @return [State] The new +@current_state+ value.
      def make_transition(strategy: LoadStrategy::LAZY, **kwargs, &block)
        raise NoCurrentStateError, 'No current state to validate against!' if current_state.nil?
        state_class = current_state.class
        load_transitions(state_class, strategy: strategy) unless transitions_loaded?(state_class)
        all_transitions = @transitions[state_class]
        prefiltered_transitions = prefiltered_transitions(all_transitions, &block)
        valid_transitions = valid_transitions(prefiltered_transitions, **kwargs)
        to_execute = selection_strategy(valid_transitions)
        execute_transition(to_execute, **kwargs)
      end

      # This is a convenience method wrapping +make_transition+. It works the exact same way, except that
      # it accepts a specification of the type of state to transition into.
      #
      # *WARNING*: This method assumes that the Transition to be executed has metadata identifying the name of the
      #   target state type. If no such transition exists, this call will result in a failed transition.
      #
      # @param [LoadStrategy] strategy The load strategy for +@current_state+'s class' transitions, if they're
      #   not already loaded.
      # @param [String|Class] target_type Specification of the target type. May either be a bare class reference,
      #   or a string identifying the class name.
      # @param [KeywordArguments] **kwargs Arbitrary named arguments that will be provided
      #   to the 'when' and 'by' methods
      def make_transition_to(target_type, strategy: LoadStrategy::LAZY, **kwargs, &block)
        name = target_type.is_a?(Class) ? target_type.name : target_type
        make_transition(strategy: strategy, **kwargs) do |trx|
          name.eql?(trx.target_name) && transition_match?(trx, &block)
        end
      end

      # Execute the given transition.
      #
      # @raise [ArgumentError] If +transition+ is not a Ladon Transition instance.
      #
      # @param [KeywordArguments] **kwargs Arbitrary named arguments that will be provided
      #   to the 'by' method
      # @return [State] The new +@current_state+ value after executing the transition.
      def execute_transition(transition, **kwargs)
        raise ArgumentError, 'Must be called with a Transition instance!' unless transition.is_a?(Transition)
        transition.execute(current_state, **kwargs)
        new_state = use_state_type(transition.target_type)
        # The IE webdriver does not wait for the browser ready state after browser action. Since most of the page load
        # action happens during transition, adding a wait to halt the execution till the browser returns ready state
        @browser.wait(12_000) if @browser
        return new_state if new_state.verify_as_current_state?
        raise TransitionFailedError, "Failed to verify '#{new_state.class}' as current state"
      end

      # Filter the given list of transitions based on the model prefilter and current state.
      #
      # *Note:* if a +block+ is given, it *must* accept a single argument, which will always be a Transition instance.
      # This block will be used as an additional Boolean filter during the *prefilter* phase.
      # See +prefiltered_transitions+ for more detail.
      #
      # @param [Enumerable<Transition>] transition_options List-like enumerable containing Transition
      #   instances to filter.
      # @return [Enumerable<Transition>] List-like enumerable containing Transitions that passed the specified filters.
      def prefiltered_transitions(transition_options, &block)
        transition_options.select do |transition|
          # keep transitions that pass the filter block (if one is provided) AND pass the model-level prefilter
          transition_match?(transition, &block) && passes_prefilter?(transition)
        end
      end

      # Model-level strategy for prefiltering  transition, leveraged by +make_transition+.
      # Is an acceptance strategy; this method should return true unless you want to filter OUT the transition.
      # Returns true in all cases unless overridden.
      #
      # @abstract
      #
      # @param [Transition] _transition The transition to prefilter.
      # @return [Boolean] True if this transition is accepted by the filter, false if it fails the filter.
      def passes_prefilter?(_transition)
        true
      end

      # Get the transitions available from the current state instance.
      #
      # @raise [NoCurrentStateError] If the FSM has no +current_state+ it is operating within.
      #
      # @param [Enumerable<Transition>] transition_options List-like enumerable containing Transition
      #   instances to validate.
      # @param [KeywordArguments] **kwargs Arbitrary named arguments that will be provided
      #   to the 'when' method
      # @return [Enumerable<Transition>] List of transitions from the argument that are valid in context
      #   of the FSM's current state.
      def valid_transitions(transition_options, **kwargs)
        raise NoCurrentStateError, 'No current state to validate against!' if current_state.nil?
        transition_options.select { |transition| transition.valid_for?(current_state, **kwargs) }
      end

      # Method to select transition to execute from a set of currently valid transitions.
      #
      # @abstract
      #
      # @raise [MissingImplementationError] Unless overridden by subclass implementation.
      #
      # @param [Enumerable<Transition>] _transition_options List-like enumerable containing Transition
      #   instances to validate.
      # @return [Transition] Must return a Transition instance that should be executed.
      def selection_strategy(_transition_options)
        raise Ladon::MissingImplementationError, '#selection_strategy'
      end

      private

      # Given a transition, validate it against a given block.
      # @return True if no block given or the block returns true when called with the given transition, false otherwise.
      def transition_match?(transition, &_block)
        !block_given? || yield(transition) == true
      end
    end

    # Alias FiniteStateMachine to FSM so users have the option to save typing effort.
    FSM = FiniteStateMachine
  end
end
