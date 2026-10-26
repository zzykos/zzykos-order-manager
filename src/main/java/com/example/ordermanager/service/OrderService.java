package com.example.ordermanager.service;

import com.example.ordermanager.dto.AddItemRequest;
import com.example.ordermanager.dto.CreateOrderRequest;
import com.example.ordermanager.exception.InvalidOrderStateException;
import com.example.ordermanager.exception.OrderNotFoundException;
import com.example.ordermanager.model.Order;
import com.example.ordermanager.model.OrderItem;
import com.example.ordermanager.model.OrderStatus;
import com.example.ordermanager.repository.OrderRepository;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;

@Service
public class OrderService {

    private final OrderRepository repository;

    public OrderService(OrderRepository repository) {
        this.repository = repository;
    }

    public List<Order> getAllOrders() {
        return repository.findAll();
    }

    public List<Order> getOrdersByStatus(OrderStatus status) {
        return repository.findByStatus(status);
    }

    public Order getOrderById(Long id) {
        return repository.findById(id)
                .orElseThrow(() -> new OrderNotFoundException(id));
    }

    @Transactional
    public Order createOrder(CreateOrderRequest request) {
        Order order = new Order(request.getCustomerName());

        if (request.getItems() != null) {
            for (AddItemRequest itemReq : request.getItems()) {
                order.addItem(new OrderItem(
                        itemReq.getProductName(),
                        itemReq.getQuantity(),
                        itemReq.getUnitPrice()
                ));
            }
        }
        return repository.save(order);
    }

    @Transactional
    public Order addItem(Long orderId, AddItemRequest request) {
        Order order = getOrderById(orderId);

        if (!order.canBeModified()) {
            throw new InvalidOrderStateException(
                    "Solo se pueden modificar pedidos en estado PENDING. Actual: " + order.getStatus()
            );
        }

        OrderItem item = new OrderItem(
                request.getProductName(),
                request.getQuantity(),
                request.getUnitPrice()
        );
        order.addItem(item);
        return repository.save(order);
    }

    @Transactional
    public Order confirmOrder(Long id) {
        return transitionTo(id, OrderStatus.PENDING, OrderStatus.CONFIRMED);
    }

    @Transactional
    public Order shipOrder(Long id) {
        return transitionTo(id, OrderStatus.CONFIRMED, OrderStatus.SHIPPED);
    }

    @Transactional
    public Order deliverOrder(Long id) {
        return transitionTo(id, OrderStatus.SHIPPED, OrderStatus.DELIVERED);
    }

    @Transactional
    public Order cancelOrder(Long id) {
        Order order = getOrderById(id);

        if (order.getStatus() == OrderStatus.DELIVERED) {
            throw new InvalidOrderStateException(
                    "Un pedido entregado no puede cancelarse"
            );
        }
        if (order.getStatus() == OrderStatus.CANCELLED) {
            throw new InvalidOrderStateException("El pedido ya está cancelado");
        }

        order.setStatus(OrderStatus.CANCELLED);
        return repository.save(order);
    }

    private Order transitionTo(Long id, OrderStatus expected, OrderStatus target) {
        Order order = getOrderById(id);

        if (order.getStatus() != expected) {
            throw new InvalidOrderStateException(
                    order.getStatus().name(),
                    target.name()
            );
        }

        order.setStatus(target);
        return repository.save(order);
    }

    @Transactional
    public void deleteOrder(Long id) {
        if (!repository.existsById(id)) {
            throw new OrderNotFoundException(id);
        }
        repository.deleteById(id);
    }
}
