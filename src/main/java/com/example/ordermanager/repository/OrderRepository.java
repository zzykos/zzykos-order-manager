package com.example.ordermanager.repository;

import com.example.ordermanager.model.Order;
import com.example.ordermanager.model.OrderStatus;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.stereotype.Repository;

import java.util.List;

@Repository
public interface OrderRepository extends JpaRepository<Order, Long> {

    List<Order> findByStatus(OrderStatus status);

    List<Order> findByCustomerNameContainingIgnoreCase(String customerName);
}
